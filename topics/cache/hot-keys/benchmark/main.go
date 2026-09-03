package main

import (
	"flag"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"
)

type workload struct {
	name      string
	requests  []int
	keyCounts []int
}

func makeWorkloads(requestCount, keyCount int, seed int64) []workload {
	uniform := workload{name: "uniform", requests: make([]int, requestCount), keyCounts: make([]int, keyCount)}
	hot50 := workload{name: "hot-50", requests: make([]int, requestCount), keyCounts: make([]int, keyCount)}
	zipf := workload{name: "zipf-1.2", requests: make([]int, requestCount), keyCounts: make([]int, keyCount)}
	zipfGenerator := rand.NewZipf(rand.New(rand.NewSource(seed)), 1.2, 1, uint64(keyCount-1))

	for i := range requestCount {
		uniformKey := i % keyCount
		uniform.requests[i] = uniformKey
		uniform.keyCounts[uniformKey]++

		hotKey := 0
		if i%2 == 1 {
			hotKey = 1 + (i/2)%(keyCount-1)
		}
		hot50.requests[i] = hotKey
		hot50.keyCounts[hotKey]++

		zipfKey := int(zipfGenerator.Uint64())
		zipf.requests[i] = zipfKey
		zipf.keyCounts[zipfKey]++
	}
	return []workload{uniform, zipf, hot50}
}

type result struct {
	workload           string
	nodes              int
	replicatedKeys     int
	replicasPerHotKey  int
	hottestKeyRequests int
	busiestNode        int
	busiestNodeShare   float64
	maxToMean          float64
	maxKeyReplica      int
	minDrainTime       time.Duration
}

func distribute(w workload, nodes, replicatedKeys, replicasPerHotKey, nodeCapacity int) result {
	nodeLoads := make([]int, nodes)
	replicaLoads := make([]int, len(w.keyCounts)*replicasPerHotKey)

	for requestID, key := range w.requests {
		primary := int(mix64(uint64(key)) % uint64(nodes))
		replica := 0
		if key < replicatedKeys && replicasPerHotKey > 1 {
			replica = int(mix64(uint64(requestID)+0x9e3779b97f4a7c15) % uint64(replicasPerHotKey))
		}
		node := (primary + replica) % nodes
		nodeLoads[node]++
		replicaLoads[key*replicasPerHotKey+replica]++
	}

	busiestNode := max(nodeLoads)
	return result{
		workload:           w.name,
		nodes:              nodes,
		replicatedKeys:     replicatedKeys,
		replicasPerHotKey:  replicasPerHotKey,
		hottestKeyRequests: max(w.keyCounts),
		busiestNode:        busiestNode,
		busiestNodeShare:   float64(busiestNode) / float64(len(w.requests)),
		maxToMean:          float64(busiestNode) / (float64(len(w.requests)) / float64(nodes)),
		maxKeyReplica:      max(replicaLoads),
		minDrainTime:       time.Duration(float64(busiestNode) / float64(nodeCapacity) * float64(time.Second)),
	}
}

func max(values []int) int {
	maximum := 0
	for _, value := range values {
		if value > maximum {
			maximum = value
		}
	}
	return maximum
}

func mix64(value uint64) uint64 {
	value ^= value >> 30
	value *= 0xbf58476d1ce4e5b9
	value ^= value >> 27
	value *= 0x94d049bb133111eb
	return value ^ (value >> 31)
}

func parsePositiveInts(input string) ([]int, error) {
	parts := strings.Split(input, ",")
	values := make([]int, 0, len(parts))
	for _, part := range parts {
		value, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || value <= 0 {
			return nil, fmt.Errorf("invalid positive integer %q", part)
		}
		values = append(values, value)
	}
	return values, nil
}

func printResult(r result) {
	fmt.Printf("| %s | %d | %d | %d | %d | %d | %.2f%% | %.2fx | %d | %s |\n",
		r.workload,
		r.nodes,
		r.replicatedKeys,
		r.replicasPerHotKey,
		r.hottestKeyRequests,
		r.busiestNode,
		r.busiestNodeShare*100,
		r.maxToMean,
		r.maxKeyReplica,
		r.minDrainTime.Round(time.Millisecond),
	)
}

func main() {
	requestCount := flag.Int("requests", 1000000, "requests in each workload")
	keyCount := flag.Int("keys", 10000, "logical cache keys")
	nodeCountsFlag := flag.String("nodes", "1,4,16,64", "comma-separated cache node counts for the sharding cases")
	replicationNodes := flag.Int("replication-nodes", 16, "cache nodes used for hot-key replication cases")
	replicatedKeys := flag.Int("replicated-keys", 10, "top-ranked keys replicated in skewed workloads")
	replicaCountsFlag := flag.String("replicas", "4,16", "comma-separated replicas per identified hot key")
	nodeCapacity := flag.Int("node-capacity", 100000, "assumed requests per second handled by one cache node")
	seed := flag.Int64("seed", 1, "random seed for the Zipf workload")
	flag.Parse()

	nodeCounts, err := parsePositiveInts(*nodeCountsFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	replicaCounts, err := parsePositiveInts(*replicaCountsFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if *requestCount <= 0 || *keyCount < 2 || *replicationNodes <= 0 || *replicatedKeys <= 0 || *replicatedKeys > *keyCount || *nodeCapacity <= 0 {
		fmt.Fprintln(os.Stderr, "requests, nodes, replicated-keys, and node-capacity must be positive; keys must be at least 2")
		os.Exit(2)
	}
	for _, replicas := range replicaCounts {
		if replicas > *replicationNodes {
			fmt.Fprintln(os.Stderr, "replicas cannot exceed replication-nodes")
			os.Exit(2)
		}
	}

	allWorkloads := makeWorkloads(*requestCount, *keyCount, *seed)
	fmt.Printf("Assumed node capacity: %d requests/s\n\n", *nodeCapacity)
	fmt.Println("| Workload | Nodes | Replicated keys | Replicas/hot key | Hottest logical key | Busiest node | Busiest share | Max/mean | Max key replica | Minimum drain time |")
	fmt.Println("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
	for _, w := range allWorkloads {
		for _, nodes := range nodeCounts {
			printResult(distribute(w, nodes, 0, 1, *nodeCapacity))
		}
	}
	for _, w := range allWorkloads[1:] {
		for _, replicas := range replicaCounts {
			printResult(distribute(w, *replicationNodes, *replicatedKeys, replicas, *nodeCapacity))
		}
	}
}
