package main

// Live host stats for the owner app: CPU, RAM, disk (storage) and network (bandwidth).
// Sampled on demand (no cache): CPU and network rates are measured over a 500 ms window.

import (
	"encoding/json"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func cpuTimes() (idle, total uint64) {
	b, _ := os.ReadFile("/proc/stat")
	f := strings.Fields(strings.SplitN(string(b), "\n", 2)[0])
	for i, s := range f[1:] {
		v, _ := strconv.ParseUint(s, 10, 64)
		total += v
		if i == 3 || i == 4 {
			idle += v
		}
	}
	return
}

func netBytes() (rx, tx uint64) {
	b, _ := os.ReadFile("/proc/net/dev")
	for _, l := range strings.Split(string(b), "\n")[2:] {
		k, v, ok := strings.Cut(l, ":")
		k = strings.TrimSpace(k)
		if !ok || k == "lo" || strings.HasPrefix(k, "docker") || strings.HasPrefix(k, "veth") || strings.HasPrefix(k, "tun") {
			continue
		}
		f := strings.Fields(v)
		if len(f) >= 9 {
			r, _ := strconv.ParseUint(f[0], 10, 64)
			t, _ := strconv.ParseUint(f[8], 10, 64)
			rx += r
			tx += t
		}
	}
	return
}

func memInfo() (total, avail uint64) {
	b, _ := os.ReadFile("/proc/meminfo")
	for _, l := range strings.Split(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		v, _ := strconv.ParseUint(f[1], 10, 64)
		switch f[0] {
		case "MemTotal:":
			total = v * 1024
		case "MemAvailable:":
			avail = v * 1024
		}
	}
	return
}

func sysStatsAdmin(w http.ResponseWriter, r *http.Request, p string) bool {
	if p != "/admin/system" || r.Method != "GET" {
		return false
	}
	i0, t0 := cpuTimes()
	rx0, tx0 := netBytes()
	st := time.Now()
	time.Sleep(500 * time.Millisecond)
	i1, t1 := cpuTimes()
	rx1, tx1 := netBytes()
	dt := time.Since(st).Seconds()
	cpu := 0.0
	if t1 > t0 {
		cpu = 100 * (1 - float64(i1-i0)/float64(t1-t0))
	}
	mt, ma := memInfo()
	var fs syscall.Statfs_t
	syscall.Statfs("/", &fs)
	dTotal := fs.Blocks * uint64(fs.Bsize)
	dFree := fs.Bavail * uint64(fs.Bsize)
	la, _ := os.ReadFile("/proc/loadavg")
	up, _ := os.ReadFile("/proc/uptime")
	host, _ := os.Hostname()
	upS, _ := strconv.ParseFloat(strings.Fields(string(up) + " 0")[0], 64)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]any{
		"host": host, "sampled_at": time.Now().Unix(), "uptime_s": int64(upS),
		"cpu":     map[string]any{"cores": runtime.NumCPU(), "percent": cpu, "load": strings.Fields(string(la))[:3]},
		"memory":  map[string]any{"total": mt, "used": mt - ma, "available": ma},
		"storage": map[string]any{"mount": "/", "total": dTotal, "used": dTotal - fs.Bfree*uint64(fs.Bsize), "free": dFree},
		"bandwidth": map[string]any{"rx_bps": float64(rx1-rx0) / dt, "tx_bps": float64(tx1-tx0) / dt,
			"rx_total": rx1, "tx_total": tx1, "since": "boot"},
	})
	return true
}
