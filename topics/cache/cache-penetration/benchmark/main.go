package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"time"
)

type bloomFilter struct {
	bits   []uint64
	size   uint64
	hashes uint64
}

func newBloomFilter(itemCount, bitsPerItem int) *bloomFilter {
	size := uint64(itemCount * bitsPerItem)
	words := (size + 63) / 64
	hashes := uint64(math.Round(float64(bitsPerItem) * math.Ln2))
	if hashes == 0 {
		hashes = 1
	}
	return &bloomFilter{bits: make([]uint64, words), size: size, hashes: hashes}
}

func (f *bloomFilter) add(key uint64) {
	h1, h2 := bloomHashes(key)
	for i := uint64(0); i < f.hashes; i++ {
		index := (h1 + i*h2) % f.size
		f.bits[index/64] |= uint64(1) << (index % 64)
	}
}

func (f *bloomFilter) mightContain(key uint64) bool {
	h1, h2 := bloomHashes(key)
	for i := uint64(0); i < f.hashes; i++ {
		index := (h1 + i*h2) % f.size
		if f.bits[index/64]&(uint64(1)<<(index%64)) == 0 {
			return false
		}
	}
	return true
}

func bloomHashes(key uint64) (uint64, uint64) {
	h1 := mix64(key + 0x9e3779b97f4a7c15)
	h2 := mix64(key+0xd1b54a32d192ed03) | 1
	return h1, h2
}

func mix64(value uint64) uint64 {
	value ^= value >> 30
	value *= 0xbf58476d1ce4e5b9
	value ^= value >> 27
	value *= 0x94d049bb133111eb
	return value ^ (value >> 31)
}

type workload struct {
	name string
	keys []uint64
}

func workloads(validKeys, requests, repeatedKeys int) []workload {
	repeated := workload{name: "repeated", keys: make([]uint64, requests)}
	unique := workload{name: "unique", keys: make([]uint64, requests)}
	for i := range requests {
		repeated.keys[i] = uint64(validKeys + i%repeatedKeys)
		unique.keys[i] = uint64(validKeys + i)
	}
	return []workload{repeated, unique}
}

type strategy struct {
	name         string
	bitsPerItem  int
	cacheMissing bool
}

var strategies = []strategy{
	{name: "none"},
	{name: "negative", cacheMissing: true},
	{name: "bloom-4", bitsPerItem: 4},
	{name: "bloom-8", bitsPerItem: 8},
	{name: "bloom-12", bitsPerItem: 12},
	{name: "bloom-8+negative", bitsPerItem: 8, cacheMissing: true},
}

type result struct {
	workload          string
	strategy          string
	requests          int
	originCalls       int
	bloomRejected     int
	bloomFalsePos     int
	negativeHits      int
	negativeEntries   int
	bloomBytes        int
	hasBloom          bool
	modeledOriginWork time.Duration
}

func run(w workload, s strategy, validKeys int, originCost time.Duration) result {
	var filter *bloomFilter
	if s.bitsPerItem > 0 {
		filter = newBloomFilter(validKeys, s.bitsPerItem)
		for key := range validKeys {
			filter.add(uint64(key))
		}
	}

	var negative map[uint64]struct{}
	if s.cacheMissing {
		negative = make(map[uint64]struct{})
	}

	r := result{workload: w.name, strategy: s.name, requests: len(w.keys), hasBloom: filter != nil}
	if filter != nil {
		r.bloomBytes = len(filter.bits) * 8
	}
	for _, key := range w.keys {
		if filter != nil {
			if !filter.mightContain(key) {
				r.bloomRejected++
				continue
			}
			r.bloomFalsePos++
		}
		if _, ok := negative[key]; ok {
			r.negativeHits++
			continue
		}
		r.originCalls++
		if negative != nil {
			negative[key] = struct{}{}
		}
	}
	r.negativeEntries = len(negative)
	r.modeledOriginWork = time.Duration(r.originCalls) * originCost
	return r
}

func main() {
	validKeys := flag.Int("valid-keys", 100000, "number of existing keys inserted into each Bloom filter")
	requests := flag.Int("requests", 10000, "number of nonexistent-key requests per workload")
	repeatedKeys := flag.Int("repeated-keys", 100, "distinct nonexistent keys in the repeated workload")
	originCost := flag.Duration("origin-cost", 5*time.Millisecond, "assumed cost of one origin lookup")
	flag.Parse()

	if *validKeys <= 0 || *requests <= 0 || *repeatedKeys <= 0 || *repeatedKeys > *requests || *originCost < 0 {
		fmt.Fprintln(os.Stderr, "key counts and requests must be positive, repeated-keys cannot exceed requests, and origin-cost cannot be negative")
		os.Exit(2)
	}

	fmt.Printf("Assumed origin cost: %s per lookup\n\n", *originCost)
	fmt.Println("| Workload | Strategy | Origin calls | Avoided origin | Bloom false positives | Negative hits | Negative entries | Bloom memory | Modeled origin work |")
	fmt.Println("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
	for _, w := range workloads(*validKeys, *requests, *repeatedKeys) {
		for _, s := range strategies {
			r := run(w, s, *validKeys, *originCost)
			falsePositive := "-"
			memory := "-"
			if r.hasBloom {
				falsePositive = fmt.Sprintf("%.2f%%", float64(r.bloomFalsePos)/float64(r.requests)*100)
				memory = fmt.Sprintf("%.1f KiB", float64(r.bloomBytes)/1024)
			}
			fmt.Printf("| %s | %s | %d | %.2f%% | %s | %d | %d | %s | %s |\n",
				r.workload,
				r.strategy,
				r.originCalls,
				float64(r.requests-r.originCalls)/float64(r.requests)*100,
				falsePositive,
				r.negativeHits,
				r.negativeEntries,
				memory,
				r.modeledOriginWork,
			)
		}
	}
}
