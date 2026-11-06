//go:build windows

package metrics

import "testing"

// One real, read-only snapshot: this is the check that the status page's
// backend actually returns usable numbers on this machine.
func TestCollectReturnsSnapshot(t *testing.T) {
	s := NewCollector().Collect()

	if s.MemTotal == 0 {
		t.Fatal("MemTotal is zero")
	}
	if s.CPUCores == 0 {
		t.Fatal("CPUCores is zero")
	}
	if s.CPUPercent < 0 || s.CPUPercent > 100 {
		t.Fatalf("CPUPercent out of range: %v", s.CPUPercent)
	}
	if s.MemPercent < 0 || s.MemPercent > 100 {
		t.Fatalf("MemPercent out of range: %v", s.MemPercent)
	}
	if len(s.Disks) == 0 {
		t.Fatal("no disks reported")
	}
	if s.HealthScore < 0 || s.HealthScore > 100 {
		t.Fatalf("HealthScore out of range: %d", s.HealthScore)
	}
	if s.HealthMessage == "" {
		t.Fatal("HealthMessage is empty")
	}
}
