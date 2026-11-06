//go:build windows

// Package metrics collects one read-only system snapshot for the GUI status page.
// It is intentionally separate from cmd/status (the legacy TUI) so the GUI can
// evolve without risking the shipped CLI tool.
package metrics

import (
	"context"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/host"
	"github.com/shirou/gopsutil/v3/mem"
	gnet "github.com/shirou/gopsutil/v3/net"
	"github.com/shirou/gopsutil/v3/process"
)

type Snapshot struct {
	CollectedAt   time.Time `json:"CollectedAt"`
	HealthScore   int       `json:"HealthScore"`
	HealthMessage string    `json:"HealthMessage"`

	Hostname      string  `json:"Hostname"`
	OS            string  `json:"OS"`
	Platform      string  `json:"Platform"`
	UptimeSeconds int64   `json:"UptimeSeconds"`
	CPUModel      string  `json:"CPUModel"`
	CPUCores      int     `json:"CPUCores"`
	CPUPercent    float64 `json:"CPUPercent"`

	MemTotal    uint64  `json:"MemTotal"`
	MemUsed     uint64  `json:"MemUsed"`
	MemPercent  float64 `json:"MemPercent"`
	SwapTotal   uint64  `json:"SwapTotal"`
	SwapUsed    uint64  `json:"SwapUsed"`
	SwapPercent float64 `json:"SwapPercent"`

	Disks []DiskInfo `json:"Disks"`

	Networks      []NetworkInfo `json:"Networks"`
	NetRecvPerSec float64       `json:"NetRecvPerSec"`
	NetSentPerSec float64       `json:"NetSentPerSec"`

	BatteryPercent  int  `json:"BatteryPercent"`
	BatteryCharging bool `json:"BatteryCharging"`
	BatteryPresent  bool `json:"BatteryPresent"`

	TopProcesses []ProcessInfo `json:"TopProcesses"`
}

type DiskInfo struct {
	Device      string  `json:"Device"`
	Mountpoint  string  `json:"Mountpoint"`
	Total       uint64  `json:"Total"`
	Used        uint64  `json:"Used"`
	Free        uint64  `json:"Free"`
	UsedPercent float64 `json:"UsedPercent"`
	Fstype      string  `json:"Fstype"`
}

type NetworkInfo struct {
	Name        string `json:"Name"`
	BytesSent   uint64 `json:"BytesSent"`
	BytesRecv   uint64 `json:"BytesRecv"`
	PacketsSent uint64 `json:"PacketsSent"`
	PacketsRecv uint64 `json:"PacketsRecv"`
}

type ProcessInfo struct {
	PID    int32   `json:"PID"`
	Name   string  `json:"Name"`
	CPU    float64 `json:"CPU"`
	Memory uint64  `json:"Memory"`
	MemPct float32 `json:"MemPct"`
}

type Collector struct {
	mu       sync.Mutex
	prevRecv uint64
	prevSent uint64
	prevTime time.Time
}

func NewCollector() *Collector { return &Collector{} }

func (c *Collector) Collect() Snapshot {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()

	s := Snapshot{CollectedAt: time.Now()}

	if info, err := host.InfoWithContext(ctx); err == nil {
		s.Hostname = info.Hostname
		s.OS = info.OS
		s.Platform = strings.TrimSpace(info.Platform + " " + info.PlatformVersion)
		s.UptimeSeconds = int64(info.Uptime)
	}
	if info, err := cpu.InfoWithContext(ctx); err == nil && len(info) > 0 {
		s.CPUModel = info[0].ModelName
	}
	s.CPUCores = runtime.NumCPU()
	// 300ms gives a stable first reading without the 1s cost of the TUI collector.
	if pct, err := cpu.PercentWithContext(ctx, 300*time.Millisecond, false); err == nil && len(pct) > 0 {
		s.CPUPercent = pct[0]
	}
	if m, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		s.MemTotal, s.MemUsed, s.MemPercent = m.Total, m.Used, m.UsedPercent
	}
	if m, err := mem.SwapMemoryWithContext(ctx); err == nil {
		s.SwapTotal, s.SwapUsed, s.SwapPercent = m.Total, m.Used, m.UsedPercent
	}

	if parts, err := disk.PartitionsWithContext(ctx, false); err == nil {
		for _, p := range parts {
			dev := strings.ToUpper(p.Device)
			if len(dev) < 2 || dev[1] != ':' {
				continue
			}
			if u, err := disk.UsageWithContext(ctx, p.Mountpoint); err == nil {
				s.Disks = append(s.Disks, DiskInfo{
					Device: p.Device, Mountpoint: p.Mountpoint,
					Total: u.Total, Used: u.Used, Free: u.Free,
					UsedPercent: u.UsedPercent, Fstype: p.Fstype,
				})
			}
		}
	}

	var recv, sent uint64
	if io, err := gnet.IOCountersWithContext(ctx, true); err == nil {
		for _, n := range io {
			if n.Name == "Loopback Pseudo-Interface 1" || (n.BytesSent == 0 && n.BytesRecv == 0) {
				continue
			}
			s.Networks = append(s.Networks, NetworkInfo{
				Name: n.Name, BytesSent: n.BytesSent, BytesRecv: n.BytesRecv,
				PacketsSent: n.PacketsSent, PacketsRecv: n.PacketsRecv,
			})
			recv += n.BytesRecv
			sent += n.BytesSent
		}
	}

	c.mu.Lock()
	now := time.Now()
	if !c.prevTime.IsZero() {
		secs := now.Sub(c.prevTime).Seconds()
		if secs > 0.2 {
			if recv >= c.prevRecv {
				s.NetRecvPerSec = float64(recv-c.prevRecv) / secs
			}
			if sent >= c.prevSent {
				s.NetSentPerSec = float64(sent-c.prevSent) / secs
			}
		}
	}
	c.prevRecv, c.prevSent, c.prevTime = recv, sent, now
	c.mu.Unlock()

	if pct, charging, present := battery(); present {
		s.BatteryPercent, s.BatteryCharging, s.BatteryPresent = pct, charging, true
	}

	if procs, err := process.ProcessesWithContext(ctx); err == nil {
		list := make([]ProcessInfo, 0, len(procs))
		for _, p := range procs {
			name, err := p.NameWithContext(ctx)
			if err != nil || name == "" {
				continue
			}
			cpuPct, _ := p.CPUPercentWithContext(ctx)
			memPct, _ := p.MemoryPercentWithContext(ctx)
			if cpuPct <= 0 && memPct <= 0 {
				continue
			}
			var bytes uint64
			if s.MemTotal > 0 {
				bytes = uint64(float64(s.MemTotal) * float64(memPct) / 100)
			}
			list = append(list, ProcessInfo{
				PID: p.Pid, Name: name, CPU: cpuPct, Memory: bytes, MemPct: memPct,
			})
		}
		sort.Slice(list, func(i, j int) bool {
			if list[i].CPU == list[j].CPU {
				return list[i].Memory > list[j].Memory
			}
			return list[i].CPU > list[j].CPU
		})
		if len(list) > 8 {
			list = list[:8]
		}
		s.TopProcesses = list
	}

	s.HealthScore, s.HealthMessage = health(s)
	return s
}

func health(s Snapshot) (int, string) {
	score := 100
	var issues []string

	switch {
	case s.CPUPercent > 90:
		score -= 30
		issues = append(issues, "CPU 负载很高")
	case s.CPUPercent > 70:
		score -= 15
		issues = append(issues, "CPU 负载偏高")
	}

	switch {
	case s.MemPercent > 90:
		score -= 25
		issues = append(issues, "内存压力很高")
	case s.MemPercent > 80:
		score -= 12
		issues = append(issues, "内存压力偏高")
	}

	for _, d := range s.Disks {
		if d.UsedPercent > 95 {
			score -= 20
			issues = append(issues, "磁盘空间紧张")
			break
		}
		if d.UsedPercent > 85 {
			score -= 10
			issues = append(issues, "磁盘空间偏低")
			break
		}
	}

	if s.SwapPercent > 80 {
		score -= 10
		issues = append(issues, "虚拟内存吃紧")
	}
	if s.BatteryPresent && !s.BatteryCharging && s.BatteryPercent <= 15 {
		score -= 10
		issues = append(issues, "电量偏低")
	}

	if score < 0 {
		score = 0
	}
	if len(issues) > 0 {
		return score, strings.Join(issues, " · ")
	}
	switch {
	case score >= 90:
		return score, "很好"
	case score >= 70:
		return score, "良好"
	case score >= 50:
		return score, "一般"
	default:
		return score, "需要留意"
	}
}

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procGetSystemPowerStatus = kernel32.NewProc("GetSystemPowerStatus")
)

type systemPowerStatus struct {
	ACLineStatus        byte
	BatteryFlag         byte
	BatteryLifePercent  byte
	SystemStatusFlag    byte
	BatteryLifeTime     uint32
	BatteryFullLifeTime uint32
}

func battery() (int, bool, bool) {
	var st systemPowerStatus
	ok, _, _ := procGetSystemPowerStatus.Call(uintptr(unsafe.Pointer(&st)))
	if ok == 0 || st.BatteryLifePercent == 255 {
		return 0, false, false
	}
	return int(st.BatteryLifePercent), st.ACLineStatus == 1, true
}
