// WebRTC/PCM media process for one HomeLine call. The AT owner passes an
// already-open, nonblocking audio FD. Signaling HTTP stays on loopback.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"golang.org/x/sys/unix"
)

const (
	frameBytes = 320
	frameTime  = 20 * time.Millisecond
)

var pcma = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMA, ClockRate: 8000, Channels: 1}
var opus = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}

type mediaServer struct {
	api    *webrtc.API
	pcmFD  int
	token  string
	opus   *opusLibrary
	record *recording
	mu     sync.Mutex
	active *mediaSession
}

type mediaSession struct {
	pc      *webrtc.PeerConnection
	enabled atomic.Bool
	stop    context.CancelFunc
	offer   string
	answer  webrtc.SessionDescription
	codec   string
}

func newMediaAPI(udp net.PacketConn, publicIP string, useOpus bool) (*webrtc.API, error) {
	var codecs webrtc.MediaEngine
	if useOpus {
		if err := codecs.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: opus, PayloadType: 111}, webrtc.RTPCodecTypeAudio); err != nil {
			return nil, err
		}
	}
	if err := codecs.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: pcma, PayloadType: 8}, webrtc.RTPCodecTypeAudio); err != nil {
		return nil, err
	}
	var settings webrtc.SettingEngine
	settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	if addr, ok := udp.LocalAddr().(*net.UDPAddr); ok && addr.IP.IsLoopback() {
		settings.SetIncludeLoopbackCandidate(true)
	}
	settings.SetICEUDPMux(webrtc.NewICEUDPMux(nil, udp))
	if publicIP != "" {
		ip := net.ParseIP(publicIP)
		if ip == nil || ip.To4() == nil {
			return nil, errors.New("invalid media public IPv4")
		}
		settings.SetNAT1To1IPs([]string{publicIP}, webrtc.ICECandidateTypeHost)
	}
	return webrtc.NewAPI(webrtc.WithMediaEngine(&codecs), webrtc.WithSettingEngine(settings)), nil
}

func main() {
	addr := flag.String("http", "127.0.0.1:14676", "loopback signaling address")
	iceAddr := flag.String("ice", "127.0.0.1:0", "IPv4 UDP media address")
	publicIP := flag.String("public-ip", "", "media address advertised through one-to-one UDP forwarding")
	pcmFD := flag.Int("pcm-fd", -1, "inherited EC20 audio file descriptor")
	tokenPath := flag.String("token-file", "", "read-only local API token file")
	recordPath := flag.String("recording-file", "", "private raw PCM path for an explicitly started recording")
	flag.Parse()
	host, _, err := net.SplitHostPort(*addr)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || *pcmFD < 3 || *tokenPath == "" {
		log.Fatal("provide a loopback HTTP address, audio FD and token file")
	}
	token, err := os.ReadFile(*tokenPath)
	if err != nil || len(strings.TrimSpace(string(token))) < 24 {
		log.Fatal("invalid media API token file")
	}
	udp, err := net.ListenPacket("udp4", *iceAddr)
	if err != nil {
		log.Fatal(err)
	}
	defer udp.Close()
	codecs, err := loadOpus()
	if err != nil {
		log.Printf("Opus unavailable, using PCMA: %v", err)
	}
	api, err := newMediaAPI(udp, *publicIP, codecs != nil)
	if err != nil {
		log.Fatal(err)
	}
	if err := unix.SetNonblock(*pcmFD, true); err != nil {
		log.Fatal(err)
	}
	server := &mediaServer{api: api, pcmFD: *pcmFD, token: strings.TrimSpace(string(token)),
		opus: codecs, record: &recording{path: *recordPath}}
	httpServer := &http.Server{Addr: *addr, Handler: server, ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 15 * time.Second}
	log.Fatal(httpServer.ListenAndServe())
}

func (s *mediaServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.token)) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case r.Method == "POST" && r.URL.Path == "/offer":
		var offer webrtc.SessionDescription
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		if err := json.NewDecoder(r.Body).Decode(&offer); err != nil || offer.Type != webrtc.SDPTypeOffer {
			http.Error(w, "invalid offer", http.StatusBadRequest)
			return
		}
		if s.active != nil {
			if s.active.offer == offer.SDP {
				writeJSON(w, s.active.answer)
			} else {
				http.Error(w, "media session already negotiated", http.StatusConflict)
			}
			return
		}
		session, err := s.negotiate(r.Context(), offer)
		if err != nil {
			log.Printf("media negotiation failed: %v", err)
			http.Error(w, "negotiation failed", http.StatusBadRequest)
			return
		}
		s.active = session
		writeJSON(w, session.answer)
	case r.Method == "GET" && r.URL.Path == "/status":
		state, codec := "idle", ""
		if s.active != nil {
			state, codec = s.active.pc.ConnectionState().String(), s.active.codec
		}
		writeJSON(w, map[string]string{"state": state, "codec": codec})
	case r.Method == "PUT" && r.URL.Path == "/recording" && s.active != nil && s.active.enabled.Load():
		if err := s.record.start(); err != nil {
			http.Error(w, "recording unavailable", http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case r.Method == "DELETE" && r.URL.Path == "/recording":
		if err := s.record.stop(); err != nil {
			http.Error(w, "recording close failed", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case r.Method == "PUT" && r.URL.Path == "/media" && s.active != nil:
		s.active.enabled.Store(true)
		w.WriteHeader(http.StatusNoContent)
	case r.Method == "DELETE" && r.URL.Path == "/media":
		if s.active != nil {
			s.active.stop()
			s.active = nil
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}

func (s *mediaServer) negotiate(request context.Context, offer webrtc.SessionDescription) (*mediaSession, error) {
	pc, err := s.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	session := &mediaSession{pc: pc, offer: offer.SDP, stop: func() { cancel(); _ = pc.Close() }}
	var codec *opusCodec
	capability := pcma
	if s.opus != nil && strings.Contains(strings.ToLower(offer.SDP), " opus/48000/2") {
		codec, err = s.opus.open()
		if err != nil {
			session.stop()
			return nil, err
		}
		capability = opus
	}
	session.codec = strings.TrimPrefix(capability.MimeType, "audio/")
	ok := false
	defer func() {
		if !ok {
			session.stop()
			if codec != nil {
				codec.close()
			}
		}
	}()
	track, err := webrtc.NewTrackLocalStaticSample(capability, "ec20-audio", "homeline")
	if err != nil {
		return nil, err
	}
	sender, err := pc.AddTrack(track)
	if err != nil {
		return nil, err
	}
	go func() {
		for {
			if _, _, err := sender.ReadRTCP(); err != nil {
				return
			}
		}
	}()

	var packets jitterBuffer
	pc.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		usingOpus := strings.EqualFold(remote.Codec().MimeType, opus.MimeType)
		if !(usingOpus && codec != nil) && !strings.EqualFold(remote.Codec().MimeType, pcma.MimeType) {
			return
		}
		for {
			packet, _, err := remote.ReadRTP()
			if err != nil {
				return
			}
			if session.enabled.Load() && len(packet.Payload) > 0 && len(packet.Payload) <= 1500 {
				packets.push(packet.SequenceNumber, audioPacket{payload: packet.Payload, opus: usingOpus})
			}
		}
	})
	if err := pc.SetRemoteDescription(offer); err != nil {
		return nil, err
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return nil, err
	}
	gather := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		return nil, err
	}
	select {
	case <-gather:
	case <-request.Done():
		return nil, request.Err()
	case <-time.After(4 * time.Second):
		return nil, errors.New("ICE gathering timed out")
	}
	session.answer = *pc.LocalDescription()
	go func() {
		if codec != nil {
			defer codec.close()
		}
		if err := s.pump(ctx, session, track, &packets, codec); err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, context.Canceled) {
			log.Printf("PCM media ended: %v", err)
		}
		session.stop()
	}()
	ok = true
	return session, nil
}

// pcmQueue keeps sample alignment across partial reads and bounds latency.
type pcmQueue struct {
	mu    sync.Mutex
	bytes []byte
}

func (q *pcmQueue) append(p []byte) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.bytes = append(q.bytes, p...)
	if frames := len(q.bytes)/frameBytes - 5; frames > 0 {
		copy(q.bytes, q.bytes[frames*frameBytes:])
		q.bytes = q.bytes[:len(q.bytes)-frames*frameBytes]
	}
}

func (q *pcmQueue) pop(p []byte, minFrames int) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.bytes) < minFrames*frameBytes {
		return false
	}
	copy(p, q.bytes[:frameBytes])
	copy(q.bytes, q.bytes[frameBytes:])
	q.bytes = q.bytes[:len(q.bytes)-frameBytes]
	return true
}

// Keep one 20 ms frame in reserve so a late USB read does not immediately
// become a silent RTP frame. Fade the edge of a longer gap to avoid clicks.
type modemPlayout struct {
	queue      pcmQueue
	playing    bool
	lastSample int16
}

func (p *modemPlayout) next(frame []byte) {
	const edgeSamples = 32 // 4 ms at the modem's 8 kHz sample rate.
	minFrames := 1
	if !p.playing {
		minFrames = 2
	}
	if p.queue.pop(frame, minFrames) {
		if !p.playing {
			for i := 0; i < edgeSamples; i++ {
				s := int16(binary.LittleEndian.Uint16(frame[2*i:]))
				binary.LittleEndian.PutUint16(frame[2*i:], uint16(int(s)*i/edgeSamples))
			}
		}
		p.lastSample = int16(binary.LittleEndian.Uint16(frame[frameBytes-2:]))
		p.playing = true
		return
	}
	clear(frame)
	if p.playing {
		for i := 0; i < edgeSamples; i++ {
			s := int(p.lastSample) * (edgeSamples - i - 1) / edgeSamples
			binary.LittleEndian.PutUint16(frame[2*i:], uint16(s))
		}
	}
	p.playing = false
}

func (s *mediaServer) pump(ctx context.Context, session *mediaSession, track *webrtc.TrackLocalStaticSample, packets *jitterBuffer, codec *opusCodec) error {
	clock := time.NewTicker(frameTime)
	defer clock.Stop()
	var uplink pcmQueue
	var downlink modemPlayout
	var lastPacketOpus bool
	var input [frameBytes * 4]byte
	var fromModem, toModem [frameBytes]byte
	var output [1500]byte
	pending := toModem[:0]
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-clock.C:
		}
		state := session.pc.ConnectionState()
		if state == webrtc.PeerConnectionStateClosed || state == webrtc.PeerConnectionStateFailed {
			return nil
		}
		if state != webrtc.PeerConnectionStateConnected || !session.enabled.Load() {
			continue
		}
		if len(pending) == 0 {
			clear(toModem[:])
			for attempts := 0; !uplink.pop(toModem[:], 1) && attempts < 3; attempts++ {
				packet, missing := packets.pop(time.Now())
				switch {
				case missing && lastPacketOpus && codec != nil:
					uplink.append(codec.decode(nil))
				case missing || len(packet.payload) == 0:
					attempts = 3
				case packet.opus:
					lastPacketOpus = true
					uplink.append(codec.decode(packet.payload))
				default:
					lastPacketOpus = false
					out := make([]byte, 2*len(packet.payload))
					for i, sample := range packet.payload {
						binary.LittleEndian.PutUint16(out[2*i:], uint16(decodeALaw(sample)))
					}
					uplink.append(out)
				}
			}
			pending = toModem[:]
		}
		n, err := unix.Write(s.pcmFD, pending)
		if err != nil && !errors.Is(err, unix.EAGAIN) && !errors.Is(err, unix.EINTR) {
			return err
		}
		if n > 0 {
			pending = pending[n:]
		}
		n, err = unix.Read(s.pcmFD, input[:])
		if err != nil && !errors.Is(err, unix.EAGAIN) && !errors.Is(err, unix.EINTR) {
			return err
		}
		if n > 0 {
			downlink.queue.append(input[:n])
		}
		downlink.next(fromModem[:])
		encoded := output[:frameBytes/2]
		if codec != nil {
			encoded, err = codec.encode(fromModem[:], output[:])
			if err != nil {
				return err
			}
		} else {
			for i := range encoded {
				encoded[i] = encodeALaw(int16(binary.LittleEndian.Uint16(fromModem[2*i:])))
			}
		}
		if err := track.WriteSample(media.Sample{Data: encoded, Duration: frameTime}); err != nil {
			return err
		}
		if s.record != nil {
			s.record.write(toModem[:], fromModem[:])
		}
	}
}

func encodeALaw(pcm int16) byte {
	x := int(pcm)
	mask := 0xd5
	if x < 0 {
		mask = 0x55
		x = -x - 1
	}
	if x < 256 {
		return byte((x >> 4) ^ mask)
	}
	segment := 1
	for shifted := x >> 8; shifted > 1; shifted >>= 1 {
		segment++
	}
	return byte((segment<<4 | (x>>(segment+3))&15) ^ mask)
}

func decodeALaw(sample byte) int16 {
	x := int(sample ^ 0x55)
	value := (x & 15) << 4
	segment := (x >> 4) & 7
	switch segment {
	case 0:
		value += 8
	case 1:
		value += 0x108
	default:
		value = (value + 0x108) << (segment - 1)
	}
	if x&0x80 == 0 {
		value = -value
	}
	return int16(value)
}
