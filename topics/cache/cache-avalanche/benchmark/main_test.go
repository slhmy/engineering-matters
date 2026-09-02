package main

import (
	"testing"
	"time"
)

func TestExpiryOffsets(t *testing.T) {
	window := 100 * time.Millisecond

	alignedOffsets := expiryOffsets(aligned, 5, window, 1)
	for _, offset := range alignedOffsets {
		if offset != 0 {
			t.Fatalf("aligned offset = %s, want 0", offset)
		}
	}

	jitteredOffsets := expiryOffsets(jittered, 100, window, 1)
	for _, offset := range jitteredOffsets {
		if offset < 0 || offset > window {
			t.Fatalf("jittered offset %s outside [0, %s]", offset, window)
		}
	}

	staggeredOffsets := expiryOffsets(staggered, 5, window, 1)
	if staggeredOffsets[0] != 0 || staggeredOffsets[4] != window {
		t.Fatalf("staggered endpoints = %s and %s, want 0 and %s", staggeredOffsets[0], staggeredOffsets[4], window)
	}
}

func TestPerKeyCoalescingAndOriginCapacity(t *testing.T) {
	result := run(aligned, 20, 10*time.Millisecond, 20*time.Millisecond, 5*time.Millisecond, 10*time.Millisecond, 2, 1)

	if result.calls != 20 {
		t.Fatalf("origin calls = %d, want one per key (20)", result.calls)
	}
	if result.peakActive > 2 {
		t.Fatalf("peak active origin loads = %d, capacity is 2", result.peakActive)
	}
	if result.peakWaiting == 0 {
		t.Fatal("aligned expiry did not create an origin queue")
	}
}

func TestParseCapacities(t *testing.T) {
	capacities, err := parseCapacities("0,50")
	if err != nil {
		t.Fatal(err)
	}
	if len(capacities) != 2 || capacities[0] != 0 || capacities[1] != 50 {
		t.Fatalf("capacities = %v, want [0 50]", capacities)
	}
	if _, err := parseCapacities("-1"); err == nil {
		t.Fatal("parseCapacities accepted a negative capacity")
	}
}
