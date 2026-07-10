// bench is a minimal TLS 1.3 handshake benchmark used to compare nginx
// configured for a post-quantum key exchange (X25519MLKEM768) against
// classical ECDHE (X25519). It opens a fresh TLS connection per
// iteration (no session resumption) across -conns concurrent workers,
// for -duration, and reports handshake rate, latency percentiles, and
// error count.
//
// Results are written as a single JSON object, either to stdout or to
// the file given by -out.
package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"net"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type result struct {
	Scenario         string  `json:"scenario"`
	Target           string  `json:"target"`
	TLSGroup         string  `json:"tls_group"`
	Connections      int     `json:"connections"`
	DurationSeconds  float64 `json:"duration_s"`
	TotalHandshakes  int64   `json:"total_handshakes"`
	Errors           int64   `json:"errors"`
	HandshakesPerSec float64 `json:"handshakes_per_sec"`
	MinMs            float64 `json:"min_ms"`
	P50Ms            float64 `json:"p50_ms"`
	P95Ms            float64 `json:"p95_ms"`
	P99Ms            float64 `json:"p99_ms"`
	MaxMs            float64 `json:"max_ms"`
}

func main() {
	addr := flag.String("addr", "", "host:port of the nginx target (required)")
	pqc := flag.Bool("pqc", false, "offer X25519MLKEM768 instead of X25519 as the TLS 1.3 key-exchange group")
	conns := flag.Int("conns", 20, "concurrent connections/workers")
	duration := flag.Duration("duration", 30*time.Second, "how long to run, e.g. 30s")
	scenario := flag.String("scenario", "", "label written into the results JSON")
	out := flag.String("out", "", "output file for JSON results (default: stdout)")
	flag.Parse()

	if *addr == "" {
		log.Fatal("-addr is required, e.g. -addr nginx-pqc:443")
	}

	group := tls.X25519
	groupName := "X25519"
	if *pqc {
		group = tls.X25519MLKEM768
		groupName = "X25519MLKEM768"
	}

	tlsConfig := &tls.Config{
		InsecureSkipVerify: true, // benchmark target uses a self-signed cert
		MinVersion:         tls.VersionTLS13,
		MaxVersion:         tls.VersionTLS13,
		CurvePreferences:   []tls.CurveID{group},
	}

	res := runHandshake(*addr, tlsConfig, *conns, *duration)
	res.Scenario = *scenario
	res.Target = *addr
	res.TLSGroup = groupName
	res.Connections = *conns

	writeResult(res, *out)
}

// runHandshake dials a brand-new TLS connection per iteration, on
// -conns concurrent workers, for the given duration, and records the
// wall-clock time of each connect+handshake.
func runHandshake(addr string, tlsConfig *tls.Config, conns int, duration time.Duration) result {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	deadline := time.Now().Add(duration)

	var wg sync.WaitGroup
	perWorker := make([][]time.Duration, conns)
	var errCount int64

	start := time.Now()
	for i := 0; i < conns; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			var local []time.Duration
			for time.Now().Before(deadline) {
				t0 := time.Now()
				conn, err := tls.DialWithDialer(dialer, "tcp", addr, tlsConfig)
				if err != nil {
					atomic.AddInt64(&errCount, 1)
					continue
				}
				local = append(local, time.Since(t0))
				conn.Close()
			}
			perWorker[idx] = local
		}(i)
	}
	wg.Wait()
	elapsed := time.Since(start)

	r := summarize(mergeLatencies(perWorker), elapsed)
	r.Errors = errCount
	return r
}

func mergeLatencies(chunks [][]time.Duration) []time.Duration {
	var n int
	for _, c := range chunks {
		n += len(c)
	}
	all := make([]time.Duration, 0, n)
	for _, c := range chunks {
		all = append(all, c...)
	}
	return all
}

func summarize(latencies []time.Duration, elapsed time.Duration) result {
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	n := len(latencies)
	r := result{
		DurationSeconds: elapsed.Seconds(),
		TotalHandshakes: int64(n),
	}
	if elapsed.Seconds() > 0 {
		r.HandshakesPerSec = float64(n) / elapsed.Seconds()
	}
	if n == 0 {
		return r
	}
	r.MinMs = msOf(latencies[0])
	r.MaxMs = msOf(latencies[n-1])
	r.P50Ms = msOf(percentile(latencies, 0.50))
	r.P95Ms = msOf(percentile(latencies, 0.95))
	r.P99Ms = msOf(percentile(latencies, 0.99))
	return r
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	idx := int(math.Ceil(p*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func msOf(d time.Duration) float64 {
	return float64(d.Microseconds()) / 1000.0
}

func writeResult(r result, out string) {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		log.Fatalf("marshal result: %v", err)
	}
	if out == "" {
		fmt.Println(string(data))
		return
	}
	if err := os.WriteFile(out, data, 0644); err != nil {
		log.Fatalf("write %s: %v", out, err)
	}
	fmt.Fprintf(os.Stderr, "wrote %s\n", out)
}
