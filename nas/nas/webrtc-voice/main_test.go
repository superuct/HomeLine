package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"math"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"golang.org/x/sys/unix"
)

func TestModemPlayoutAbsorbsLateReadsAndFadesLongerGaps(t *testing.T) {
	var playout modemPlayout
	var pcm, out [frameBytes]byte
	for i := 0; i < frameBytes; i += 2 {
		binary.LittleEndian.PutUint16(pcm[i:], 2000)
	}
	playout.queue.append(pcm[:])
	playout.next(out[:])
	if out != [frameBytes]byte{} {
		t.Fatal("playout started without a reserve frame")
	}
	playout.queue.append(pcm[:])
	playout.next(out[:])
	if !playout.playing || binary.LittleEndian.Uint16(out[frameBytes-2:]) != 2000 {
		t.Fatal("playout did not start after filling the reserve")
	}
	playout.next(out[:]) // USB read missed one 20 ms tick.
	if out != pcm {
		t.Fatal("one late read interrupted playout")
	}
	playout.next(out[:])
	if playout.playing || binary.LittleEndian.Uint16(out[:2]) == 0 || binary.LittleEndian.Uint16(out[62:]) != 0 {
		t.Fatal("a longer gap did not decay to silence")
	}
	playout.queue.append(pcm[:])
	playout.next(out[:])
	if out != [frameBytes]byte{} {
		t.Fatal("playout did not refill its reserve after a longer gap")
	}
}

func TestWebRTCBridgesPCMInBothDirections(t *testing.T) {
	ports, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(ports[0])
	defer unix.Close(ports[1])
	for _, fd := range ports {
		if err := unix.SetNonblock(fd, true); err != nil {
			t.Fatal(err)
		}
	}
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	api, err := newMediaAPI(udp, "", false)
	if err != nil {
		t.Fatal(err)
	}
	var clientSettings webrtc.SettingEngine
	clientSettings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	clientSettings.SetIncludeLoopbackCandidate(true)
	client, err := webrtc.NewAPI(webrtc.WithSettingEngine(clientSettings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	track, err := webrtc.NewTrackLocalStaticSample(pcma, "phone-mic", "test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.AddTrack(track); err != nil {
		t.Fatal(err)
	}
	micCode, radioCode := encodeALaw(-1234), encodeALaw(2312)
	heardRadio := make(chan struct{})
	var heardRadioOnce sync.Once
	client.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		for {
			p, _, err := track.ReadRTP()
			if err != nil {
				return
			}
			if bytes.Equal(p.Payload, bytes.Repeat([]byte{radioCode}, frameBytes/2)) {
				heardRadioOnce.Do(func() { close(heardRadio) })
			}
		}
	})
	offer, err := client.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered := webrtc.GatheringCompletePromise(client)
	if err := client.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gathered:
	case <-time.After(4 * time.Second):
		t.Fatal("client ICE gathering timed out")
	}
	server := mediaServer{api: api, pcmFD: ports[0]}
	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
	defer cancel()
	session, err := server.negotiate(ctx, *client.LocalDescription())
	if err != nil {
		t.Fatal(err)
	}
	defer session.stop()
	if err := client.SetRemoteDescription(session.answer); err != nil {
		t.Fatal(err)
	}
	session.enabled.Store(true)
	var audio [frameBytes]byte
	for i := 0; i < frameBytes; i += 2 {
		binary.LittleEndian.PutUint16(audio[i:], uint16(decodeALaw(radioCode)))
	}
	wantSample := decodeALaw(micCode)
	clock := time.NewTicker(frameTime)
	defer clock.Stop()
	gotMic, gotRadio := false, false
	var received [frameBytes * 6]byte
	var tail []byte
	for !gotMic || !gotRadio {
		select {
		case <-ctx.Done():
			t.Fatalf("media timed out: radio heard microphone=%v, phone heard radio=%v", gotMic, gotRadio)
		case <-clock.C:
			if client.ConnectionState() != webrtc.PeerConnectionStateConnected {
				continue
			}
			if n, err := unix.Write(ports[1], audio[:]); err != nil || n != len(audio) {
				t.Fatalf("writing test audio: %d %v", n, err)
			}
			if err := track.WriteSample(media.Sample{Data: bytes.Repeat([]byte{micCode}, frameBytes/2), Duration: frameTime}); err != nil {
				t.Fatal(err)
			}
			n, err := unix.Read(ports[1], received[:])
			if err != nil && err != unix.EAGAIN {
				t.Fatal(err)
			}
			if n > 0 {
				tail = append(tail, received[:n]...)
				for len(tail) >= 2 {
					if int16(binary.LittleEndian.Uint16(tail)) == wantSample {
						gotMic = true
					}
					tail = tail[2:]
				}
			}
			select {
			case <-heardRadio:
				gotRadio = true
			default:
			}
		}
	}
}

func TestOpusAndRecordingFrames(t *testing.T) {
	library, err := loadOpus()
	if err != nil {
		if os.Getenv("HOMELINE_REQUIRE_OPUS") == "1" {
			t.Fatal(err)
		}
		t.Skip(err)
	}
	codec, err := library.open()
	if err != nil {
		t.Fatal(err)
	}
	defer codec.close()

	var mic, radio [frameBytes]byte
	for i := 0; i < len(mic)/2; i++ {
		sample := int16(4000 * math.Sin(2*math.Pi*600*float64(i)/8000))
		binary.LittleEndian.PutUint16(mic[2*i:], uint16(sample))
		binary.LittleEndian.PutUint16(radio[2*i:], 2000)
	}
	payload, err := codec.encode(mic[:], make([]byte, 1276))
	if err != nil {
		t.Fatal(err)
	}
	decoded := codec.decode(payload)
	if len(decoded) != frameBytes || bytes.Equal(decoded, make([]byte, frameBytes)) {
		t.Fatal("Opus round trip did not produce a non-silent 20 ms frame")
	}
	if concealed := codec.decode(nil); len(concealed) != frameBytes {
		t.Fatalf("missing packet concealment produced %d bytes", len(concealed))
	}

	recorder := recording{path: filepath.Join(t.TempDir(), "call.pcm")}
	recorder.write(mic[:], radio[:])
	if _, err := os.Stat(recorder.path); !os.IsNotExist(err) {
		t.Fatalf("recording unexpectedly exists before opt-in: %v", err)
	}
	if err := recorder.start(); err != nil {
		t.Fatal(err)
	}
	recorder.write(mic[:], radio[:])
	if err := recorder.stop(); err != nil {
		t.Fatal(err)
	}
	recorder.write(radio[:], mic[:])
	recorded, err := os.ReadFile(recorder.path)
	if err != nil {
		t.Fatal(err)
	}
	if len(recorded) != frameBytes {
		t.Fatalf("recorded %d bytes, expected %d", len(recorded), frameBytes)
	}
	for i := 0; i < len(recorded); i += 2 {
		sample := int16(binary.LittleEndian.Uint16(mic[i:]))
		if got := int16(binary.LittleEndian.Uint16(recorded[i:])); got != (sample+2000)/2 {
			t.Fatalf("mixed sample %d = %d", i/2, got)
		}
	}
}
