package main

import (
	"encoding/binary"
	"errors"
	"log"
	"os"
	"sync"
)

const maxRecordingBytes = 30 * 60 * 8000 * 2

type recording struct {
	mu      sync.Mutex
	path    string
	file    *os.File
	written int
}

func (r *recording) start() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file != nil {
		return nil
	}
	if r.path == "" || r.written > 0 {
		return errors.New("recording unavailable")
	}
	f, err := os.OpenFile(r.path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	r.file = f
	return nil
}

func (r *recording) stop() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.close()
}

func (r *recording) close() error {
	if r.file == nil {
		return nil
	}
	err := r.file.Close()
	r.file = nil
	return err
}

func (r *recording) write(mic, radio []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return
	}
	var mixed [frameBytes]byte
	for i := 0; i < len(mixed); i += 2 {
		left := int32(int16(binary.LittleEndian.Uint16(mic[i:])))
		right := int32(int16(binary.LittleEndian.Uint16(radio[i:])))
		binary.LittleEndian.PutUint16(mixed[i:], uint16((left+right)/2))
	}
	n, err := r.file.Write(mixed[:])
	r.written += n
	if err != nil || r.written >= maxRecordingBytes {
		if err != nil {
			log.Printf("recording write failed: %v", err)
		}
		_ = r.close()
	}
}
