package main

import (
	"encoding/binary"
	"fmt"
	"runtime"

	"github.com/ebitengine/purego"
)

type opusLibrary struct {
	newEncoder     func(int32, int32, int32, *int32) uintptr
	newDecoder     func(int32, int32, *int32) uintptr
	encode         func(uintptr, *int16, int32, *byte, int32) int32
	decode         func(uintptr, *byte, int32, *int16, int32, int32) int32
	destroyEncoder func(uintptr)
	destroyDecoder func(uintptr)
}

func loadOpus() (*opusLibrary, error) {
	name := "libopus.so.0"
	if runtime.GOOS == "darwin" {
		name = "/opt/homebrew/lib/libopus.0.dylib"
		if runtime.GOARCH == "amd64" {
			name = "/usr/local/lib/libopus.0.dylib"
		}
	}
	handle, err := purego.Dlopen(name, purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, err
	}
	library := &opusLibrary{}
	for symbol, target := range map[string]any{
		"opus_encoder_create": &library.newEncoder, "opus_decoder_create": &library.newDecoder,
		"opus_encode": &library.encode, "opus_decode": &library.decode,
		"opus_encoder_destroy": &library.destroyEncoder, "opus_decoder_destroy": &library.destroyDecoder,
	} {
		address, err := purego.Dlsym(handle, symbol)
		if err != nil {
			_ = purego.Dlclose(handle)
			return nil, err
		}
		purego.RegisterFunc(target, address)
	}
	return library, nil
}

type opusCodec struct {
	lib              *opusLibrary
	encoder, decoder uintptr
}

func (library *opusLibrary) open() (*opusCodec, error) {
	const opusApplicationVoIP = 2048
	const sampleRate = 8000
	var code int32
	encoder := library.newEncoder(sampleRate, 1, opusApplicationVoIP, &code)
	if encoder == 0 {
		return nil, fmt.Errorf("creating Opus encoder: %d", code)
	}
	decoder := library.newDecoder(sampleRate, 1, &code)
	if decoder == 0 {
		library.destroyEncoder(encoder)
		return nil, fmt.Errorf("creating Opus decoder: %d", code)
	}
	return &opusCodec{library, encoder, decoder}, nil
}

func (codec *opusCodec) close() {
	codec.lib.destroyEncoder(codec.encoder)
	codec.lib.destroyDecoder(codec.decoder)
}

func (codec *opusCodec) encode(pcm []byte, output []byte) ([]byte, error) {
	var samples [frameBytes / 2]int16
	for i := range samples {
		samples[i] = int16(binary.LittleEndian.Uint16(pcm[2*i:]))
	}
	n := codec.lib.encode(codec.encoder, &samples[0], int32(len(samples)), &output[0], int32(len(output)))
	if n < 0 {
		return nil, fmt.Errorf("Opus encode failed: %d", n)
	}
	return output[:n], nil
}

func (codec *opusCodec) decode(payload []byte) []byte {
	// libopus accepts up to 120 ms per packet. A nil payload synthesizes
	// one 20 ms packet of concealment using decoder history.
	var samples [960]int16
	var data *byte
	count := int32(frameBytes / 2)
	if len(payload) > 0 {
		data = &payload[0]
		count = int32(len(samples))
	}
	n := codec.lib.decode(codec.decoder, data, int32(len(payload)), &samples[0], count, 0)
	if n <= 0 || int(n) > len(samples) {
		return nil
	}
	pcm := make([]byte, int(n)*2)
	for i, sample := range samples[:n] {
		binary.LittleEndian.PutUint16(pcm[2*i:], uint16(sample))
	}
	return pcm
}
