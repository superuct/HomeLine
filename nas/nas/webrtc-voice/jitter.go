package main

import (
	"sync"
	"time"
)

type audioPacket struct {
	payload []byte
	opus    bool
}

type jitterBuffer struct {
	mu      sync.Mutex
	packets map[uint16]audioPacket
	next    uint16
	first   time.Time
	playing bool
}

func (q *jitterBuffer) push(seq uint16, packet audioPacket) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.packets == nil {
		q.packets = make(map[uint16]audioPacket)
		q.next, q.first = seq, time.Now()
	}
	delta := int16(seq - q.next)
	if delta < 0 {
		if q.playing || delta < -5 {
			return
		}
		q.next = seq
	}
	if delta > 24 {
		clear(q.packets)
		q.next, q.first, q.playing = seq, time.Now(), false
	}
	if _, exists := q.packets[seq]; !exists {
		q.packets[seq] = packet
	}
}

func (q *jitterBuffer) pop(now time.Time) (packet audioPacket, missing bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.packets) == 0 || (!q.playing && len(q.packets) < 2 && now.Sub(q.first) < 45*time.Millisecond) {
		return audioPacket{}, false
	}
	q.playing = true
	packet, found := q.packets[q.next]
	delete(q.packets, q.next)
	q.next++
	return packet, !found
}
