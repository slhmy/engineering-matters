package main

import "testing"

func TestWorkloadShapes(t *testing.T) {
	workloadCases := makeWorkloads(1000, 100, 1)

	if hottest := max(workloadCases[0].keyCounts); hottest != 10 {
		t.Fatalf("uniform hottest key = %d, want 10", hottest)
	}
	if hot := workloadCases[2].keyCounts[0]; hot != 500 {
		t.Fatalf("hot-50 key 0 requests = %d, want 500", hot)
	}
	if zipfHottest := max(workloadCases[1].keyCounts); zipfHottest <= 10 {
		t.Fatalf("Zipf hottest key = %d, want more than uniform's 10", zipfHottest)
	}
}

func TestDistributionConservesRequests(t *testing.T) {
	w := makeWorkloads(1000, 100, 1)[2]
	r := distribute(w, 4, 10, 4, 1000)

	if r.busiestNode < 250 {
		t.Fatalf("busiest node = %d, cannot be below the mean 250", r.busiestNode)
	}
	if r.busiestNode > 1000 {
		t.Fatalf("busiest node = %d, exceeds total requests", r.busiestNode)
	}
}

func TestReplicationSplitsOneHotKey(t *testing.T) {
	w := workload{name: "one-key", requests: make([]int, 1000), keyCounts: []int{1000, 0}}
	oneReplica := distribute(w, 4, 0, 1, 1000)
	fourReplicas := distribute(w, 4, 1, 4, 1000)

	if oneReplica.maxKeyReplica != 1000 {
		t.Fatalf("single replica load = %d, want 1000", oneReplica.maxKeyReplica)
	}
	if fourReplicas.maxKeyReplica >= oneReplica.maxKeyReplica {
		t.Fatalf("replicated key load = %d, want below %d", fourReplicas.maxKeyReplica, oneReplica.maxKeyReplica)
	}
}

func TestParsePositiveInts(t *testing.T) {
	values, err := parsePositiveInts("1,4,16")
	if err != nil || len(values) != 3 || values[2] != 16 {
		t.Fatalf("values = %v, err = %v", values, err)
	}
	if _, err := parsePositiveInts("0"); err == nil {
		t.Fatal("parsePositiveInts accepted zero")
	}
}
