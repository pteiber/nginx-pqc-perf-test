// trafficmix is a mixed-traffic TLS 1.3 load generator used to compare
// nginx configured for a post-quantum key exchange (X25519MLKEM768)
// against classical ECDHE (X25519) under a realistic workload, rather
// than the raw back-to-back handshakes that the sibling bench tool
// measures.
//
// It drives two decoupled, independently-paced subsystems against one
// target for -duration:
//
//   - REQUEST: a fixed pool of warm keep-alive connections issues HTTP
//     GETs at -rps requests/sec. These reuse established connections, so
//     they measure steady-state request serving, not handshakes.
//   - HANDSHAKE: brand-new TLS connections are opened at -handshake-rate
//     per second, of which -resume-pct percent attempt TLS 1.3 session
//     resumption (the rest do a full handshake). This measures connection
//     setup cost, where the post-quantum KEM actually lands.
//
// Both subsystems fetch random-sized bodies: each request asks for
// "Range: bytes=0-(n-1)" on /payload.bin with n uniform in
// [-min-bytes,-max-bytes], so nginx replies 206 with exactly n bytes.
//
// Pacing is open-loop: a ticker feeds a small bounded queue drained by a
// worker pool; when the pool is saturated the tick is counted as
// "dropped" instead of blocking, so an achieved rate below the target
// rate is a visible saturation signal. Results are written as a single
// JSON object, to stdout or the file given by -out.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httptrace"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// config holds the parsed and validated command-line knobs.
type config struct {
	addr           string
	pqc            bool
	duration       time.Duration
	scenario       string
	out            string
	rps            int
	handshakeRate  int
	resumePct      int
	minBytes       int
	maxBytes       int
	connections    int
	handshakeConns int
}

func parseFlags() config {
	addr := flag.String("addr", "", "host:port of the nginx target (required)")
	pqc := flag.Bool("pqc", false, "offer X25519MLKEM768 instead of X25519 as the TLS 1.3 key-exchange group")
	duration := flag.Duration("duration", 30*time.Second, "how long to run, e.g. 30s")
	scenario := flag.String("scenario", "", "label written into the results JSON")
	out := flag.String("out", "", "output file for JSON results (default: stdout)")
	rps := flag.Int("rps", 200, "target HTTP request rate over the warm keep-alive pool (0 disables)")
	handshakeRate := flag.Int("handshake-rate", 50, "target new-connection (TLS handshake) rate per second (0 disables)")
	resumePct := flag.Int("resume-pct", 50, "percent of churned handshakes that attempt TLS 1.3 session resumption (0-100)")
	minBytes := flag.Int("min-bytes", 1024, "minimum response body size in bytes")
	maxBytes := flag.Int("max-bytes", 65536, "maximum response body size in bytes (must be <= payload.bin size)")
	connections := flag.Int("connections", 50, "size of the warm keep-alive connection pool (request subsystem)")
	handshakeConns := flag.Int("handshake-conns", 50, "worker pool size for the handshake-churn subsystem")
	flag.Parse()

	if *addr == "" {
		log.Fatal("-addr is required, e.g. -addr 10.0.1.5:8443")
	}
	if *minBytes < 1 {
		log.Fatalf("-min-bytes must be >= 1, got %d", *minBytes)
	}
	if *maxBytes < *minBytes {
		log.Fatalf("-max-bytes (%d) must be >= -min-bytes (%d)", *maxBytes, *minBytes)
	}
	if *resumePct < 0 || *resumePct > 100 {
		log.Fatalf("-resume-pct must be in 0..100, got %d", *resumePct)
	}

	return config{
		addr:           *addr,
		pqc:            *pqc,
		duration:       *duration,
		scenario:       *scenario,
		out:            *out,
		rps:            *rps,
		handshakeRate:  *handshakeRate,
		resumePct:      *resumePct,
		minBytes:       *minBytes,
		maxBytes:       *maxBytes,
		connections:    *connections,
		handshakeConns: *handshakeConns,
	}
}

// serverName is the SNI sent on every connection. It must be stable and
// identical across the warmup and resume configs, because Go's
// ClientSessionCache is keyed (in part) by ServerName; an empty or
// varying name silently defeats resumption.
const serverName = "localhost"

type output struct {
	Scenario        string   `json:"scenario"`
	Target          string   `json:"target"`
	TLSGroup        string   `json:"tls_group"`
	Params          params   `json:"params"`
	DurationSeconds float64  `json:"duration_s"`
	Request         reqStats `json:"request"`
	Handshake       hsStats  `json:"handshake"`
}

type params struct {
	RPS              int     `json:"rps"`
	HandshakeRate    int     `json:"handshake_rate"`
	ResumePct        int     `json:"resume_pct"`
	MinBytes         int     `json:"min_bytes"`
	MaxBytes         int     `json:"max_bytes"`
	DurationSeconds  float64 `json:"duration_s"`
	Connections      int     `json:"connections"`
	HandshakeConns   int     `json:"handshake_conns"`
	PayloadSizeBytes int64   `json:"payload_size_bytes"`
}

type pct struct {
	Min float64 `json:"min_ms"`
	P50 float64 `json:"p50_ms"`
	P95 float64 `json:"p95_ms"`
	P99 float64 `json:"p99_ms"`
	Max float64 `json:"max_ms"`
}

type reqStats struct {
	Total        int64            `json:"total"`
	AchievedRPS  float64          `json:"achieved_rps"`
	Dropped      int64            `json:"dropped"`
	Errors       int64            `json:"errors"`
	Bytes        int64            `json:"bytes"`
	StatusCounts map[string]int64 `json:"status_counts"`
	FreshConns   int64            `json:"fresh_conns"`
	ReusedConns  int64            `json:"reused_conns"`
	Latency      pct              `json:"latency"`
}

type hsStats struct {
	Total            int64   `json:"total"`
	AchievedRate     float64 `json:"achieved_rate"`
	Dropped          int64   `json:"dropped"`
	Errors           int64   `json:"errors"`
	ResumeRequested  int64   `json:"resume_requested"`
	ResumeAchieved   int64   `json:"resume_achieved"`
	ResumeRateActual float64 `json:"resume_rate_actual"`
	FullCount        int64   `json:"full_count"`
	ResumedCount     int64   `json:"resumed_count"`
	FullLatency      pct     `json:"full_latency"`
	ResumedLatency   pct     `json:"resumed_latency"`
}

func main() {
	log.SetFlags(0)
	cfg := parseFlags()

	group := tls.X25519
	groupName := "X25519"
	if cfg.pqc {
		group = tls.X25519MLKEM768
		groupName = "X25519MLKEM768"
	}

	reqCfg, resumeCfg, fullCfg := buildTLSConfigs(group)

	// Confirm the payload is large enough for the requested size range;
	// a Range whose end is past EOF makes nginx serve 200 (whole file),
	// which would corrupt the byte counts and the 206 success check.
	payloadSize, err := probePayloadSize(cfg.addr, reqCfg)
	if err != nil {
		log.Fatalf("probe %s: %v", cfg.addr, err)
	}
	if int64(cfg.maxBytes) > payloadSize {
		log.Fatalf("-max-bytes %d exceeds the target payload size %d bytes; lower -max-bytes or grow payload.bin", cfg.maxBytes, payloadSize)
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.duration)
	defer cancel()

	var (
		reqRes reqStats
		hsRes  hsStats
		wg     sync.WaitGroup
	)
	wg.Add(2)
	start := time.Now()
	go func() {
		defer wg.Done()
		reqRes = runRequestSubsystem(ctx, cfg, reqCfg)
	}()
	go func() {
		defer wg.Done()
		hsRes = runHandshakeSubsystem(ctx, cfg, resumeCfg, fullCfg)
	}()
	wg.Wait()
	elapsed := time.Since(start)

	out := output{
		Scenario:        cfg.scenario,
		Target:          cfg.addr,
		TLSGroup:        groupName,
		DurationSeconds: elapsed.Seconds(),
		Request:         reqRes,
		Handshake:       hsRes,
		Params: params{
			RPS:              cfg.rps,
			HandshakeRate:    cfg.handshakeRate,
			ResumePct:        cfg.resumePct,
			MinBytes:         cfg.minBytes,
			MaxBytes:         cfg.maxBytes,
			DurationSeconds:  cfg.duration.Seconds(),
			Connections:      cfg.connections,
			HandshakeConns:   cfg.handshakeConns,
			PayloadSizeBytes: payloadSize,
		},
	}
	writeResult(out, cfg.out)
}

// buildTLSConfigs returns three immutable configs shared read-only across
// all workers: one for the keep-alive request pool, one that offers a
// cached session for resumption, and one that forces a full handshake
// (nil cache). None of them is mutated after this point.
func buildTLSConfigs(group tls.CurveID) (reqCfg, resumeCfg, fullCfg *tls.Config) {
	base := func(cache tls.ClientSessionCache) *tls.Config {
		return &tls.Config{
			InsecureSkipVerify: true, // benchmark target uses a self-signed cert
			MinVersion:         tls.VersionTLS13,
			MaxVersion:         tls.VersionTLS13,
			CurvePreferences:   []tls.CurveID{group},
			ServerName:         serverName,
			ClientSessionCache: cache,
		}
	}
	// One shared cache seeds and is refreshed by the resume path.
	shared := tls.NewLRUClientSessionCache(0)
	return base(nil), base(shared), base(nil)
}

// runRequestSubsystem drives the keep-alive request pool at cfg.rps. It
// returns zero stats when -rps <= 0 (subsystem disabled).
func runRequestSubsystem(ctx context.Context, cfg config, tlsCfg *tls.Config) reqStats {
	if cfg.rps <= 0 || cfg.connections <= 0 {
		return reqStats{StatusCounts: map[string]int64{}}
	}

	// MaxIdleConnsPerHost must be >= the pool size or idle conns get
	// reaped and re-handshake between requests, silently defeating
	// keep-alive. IdleConnTimeout is kept above the run duration for the
	// same reason. TLS is owned entirely by DialTLSContext.
	var fresh, reused int64
	tr := &http.Transport{
		DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			d := &tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second}, Config: tlsCfg}
			return d.DialContext(ctx, network, addr)
		},
		MaxConnsPerHost:     cfg.connections,
		MaxIdleConns:        cfg.connections,
		MaxIdleConnsPerHost: cfg.connections,
		IdleConnTimeout:     cfg.duration + 30*time.Second,
		ForceAttemptHTTP2:   false,
		DisableKeepAlives:   false,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr}
	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			if info.Reused {
				atomic.AddInt64(&reused, 1)
			} else {
				atomic.AddInt64(&fresh, 1)
			}
		},
	}
	url := "https://" + cfg.addr + "/payload.bin"

	jobs := make(chan struct{}, cfg.connections)
	perWorker := make([]workerReq, cfg.connections)

	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < cfg.connections; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			w := workerReq{status: map[int]int64{}}
			for range jobs {
				n := cfg.minBytes + rand.IntN(cfg.maxBytes-cfg.minBytes+1)
				reqCtx := httptrace.WithClientTrace(ctx, trace)
				req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
				if err != nil {
					w.errors++
					continue
				}
				req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", n-1))
				t0 := time.Now()
				resp, err := client.Do(req)
				if err != nil {
					w.errors++
					continue
				}
				lat := time.Since(t0)
				nb, _ := io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				w.bytes += nb
				w.status[resp.StatusCode]++
				if resp.StatusCode == http.StatusPartialContent {
					w.lat = append(w.lat, lat)
				} else {
					w.errors++
				}
			}
			perWorker[idx] = w
		}(i)
	}

	dropped := pace(ctx, cfg.rps, jobs, func(int) struct{} { return struct{}{} })
	wg.Wait()
	elapsed := time.Since(start)

	res := reqStats{Dropped: dropped, StatusCounts: map[string]int64{}}
	var lat []time.Duration
	for _, w := range perWorker {
		res.Total += int64(len(w.lat))
		res.Errors += w.errors
		res.Bytes += w.bytes
		lat = append(lat, w.lat...)
		for code, c := range w.status {
			res.StatusCounts[strconv.Itoa(code)] += c
		}
	}
	res.FreshConns = atomic.LoadInt64(&fresh)
	res.ReusedConns = atomic.LoadInt64(&reused)
	if elapsed.Seconds() > 0 {
		res.AchievedRPS = float64(res.Total) / elapsed.Seconds()
	}
	res.Latency = summarizePct(lat)
	return res
}

type workerReq struct {
	lat    []time.Duration
	errors int64
	bytes  int64
	status map[int]int64
}

type hsJob struct{ resume bool }

// runHandshakeSubsystem churns fresh TLS connections at cfg.handshakeRate,
// asking cfg.resumePct percent of them to resume. It returns zero stats
// when -handshake-rate <= 0 (subsystem disabled).
func runHandshakeSubsystem(ctx context.Context, cfg config, resumeCfg, fullCfg *tls.Config) hsStats {
	if cfg.handshakeRate <= 0 || cfg.handshakeConns <= 0 {
		return hsStats{}
	}

	dialer := &net.Dialer{Timeout: 5 * time.Second}

	// Seed the shared session cache with one full handshake + GET so that
	// the very first resume jobs have a ticket to present. Without a read
	// after the handshake the TLS 1.3 NewSessionTicket is never cached.
	if cfg.resumePct > 0 {
		if conn, err := tls.DialWithDialer(dialer, "tcp", cfg.addr, resumeCfg); err == nil {
			doGet(conn, cfg.addr, cfg.minBytes)
			conn.Close()
		}
	}

	jobs := make(chan hsJob, cfg.handshakeConns)
	perWorker := make([]workerHS, cfg.handshakeConns)

	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < cfg.handshakeConns; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			w := workerHS{}
			for job := range jobs {
				tlsCfg := fullCfg
				if job.resume {
					tlsCfg = resumeCfg
					w.resumeRequested++
				}
				n := cfg.minBytes + rand.IntN(cfg.maxBytes-cfg.minBytes+1)
				t0 := time.Now()
				conn, err := tls.DialWithDialer(dialer, "tcp", cfg.addr, tlsCfg)
				if err != nil {
					w.errors++
					continue
				}
				lat := time.Since(t0)
				did := conn.ConnectionState().DidResume
				// One request keeps the exchange realistic and lets the
				// session ticket be read into the shared cache for the
				// next resume job.
				doGet(conn, cfg.addr, n)
				conn.Close()
				if job.resume && did {
					w.resumeAchieved++
				}
				if did {
					w.resumedLat = append(w.resumedLat, lat)
				} else {
					w.fullLat = append(w.fullLat, lat)
				}
			}
			perWorker[idx] = w
		}(i)
	}

	// Even (Bresenham-style) resume/full labelling: an accumulator adds
	// resumePct per job and flags a resume each time it crosses 100. This
	// reproduces the requested split closely over any prefix length,
	// unlike i%100<pct, whose final partial cycle skews short runs. The
	// closure runs only on the single pacer goroutine, so acc needs no
	// synchronization.
	acc := 0
	dropped := pace(ctx, cfg.handshakeRate, jobs, func(int) hsJob {
		acc += cfg.resumePct
		if acc >= 100 {
			acc -= 100
			return hsJob{resume: true}
		}
		return hsJob{resume: false}
	})
	wg.Wait()
	elapsed := time.Since(start)

	res := hsStats{Dropped: dropped}
	var full, resumed []time.Duration
	for _, w := range perWorker {
		res.Errors += w.errors
		res.ResumeRequested += w.resumeRequested
		res.ResumeAchieved += w.resumeAchieved
		full = append(full, w.fullLat...)
		resumed = append(resumed, w.resumedLat...)
	}
	res.FullCount = int64(len(full))
	res.ResumedCount = int64(len(resumed))
	res.Total = res.FullCount + res.ResumedCount
	if elapsed.Seconds() > 0 {
		res.AchievedRate = float64(res.Total) / elapsed.Seconds()
	}
	if res.Total > 0 {
		res.ResumeRateActual = float64(res.ResumedCount) / float64(res.Total)
	}
	res.FullLatency = summarizePct(full)
	res.ResumedLatency = summarizePct(resumed)
	return res
}

type workerHS struct {
	fullLat         []time.Duration
	resumedLat      []time.Duration
	errors          int64
	resumeRequested int64
	resumeAchieved  int64
}

// doGet writes one minimal HTTP/1.1 range request over conn and drains
// the response. Errors are ignored: the handshake (already measured) is
// what matters; the request is only for realism and ticket delivery.
func doGet(conn net.Conn, addr string, n int) {
	host := addr
	if h, _, err := net.SplitHostPort(addr); err == nil {
		host = h
	}
	fmt.Fprintf(conn, "GET /payload.bin HTTP/1.1\r\nHost: %s\r\nRange: bytes=0-%d\r\nConnection: close\r\n\r\n", host, n-1)
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}

// pace runs an open-loop rate limiter: it ticks at 1/rate and offers a
// job (built by mk) to the bounded jobs channel with a non-blocking send,
// counting a drop whenever the workers can't keep up. It owns the channel
// and is the only closer, so workers ranging over it exit cleanly when
// the deadline context fires.
func pace[T any](ctx context.Context, rate int, jobs chan<- T, mk func(i int) T) int64 {
	var dropped int64
	ticker := time.NewTicker(time.Second / time.Duration(rate))
	defer ticker.Stop()
	i := 0
	for {
		select {
		case <-ctx.Done():
			close(jobs)
			return dropped
		case <-ticker.C:
			job := mk(i)
			i++
			select {
			case jobs <- job:
			default:
				dropped++
			}
		}
	}
}

// probePayloadSize fetches a single byte to learn the total size of
// /payload.bin from the Content-Range header (or Content-Length if the
// server ignored the range), so main can reject a -max-bytes that would
// run past EOF.
func probePayloadSize(addr string, tlsCfg *tls.Config) (int64, error) {
	tr := &http.Transport{
		DialTLSContext: func(ctx context.Context, network, a string) (net.Conn, error) {
			d := &tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second}, Config: tlsCfg}
			return d.DialContext(ctx, network, a)
		},
		DisableKeepAlives: true,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 10 * time.Second}

	req, err := http.NewRequest(http.MethodGet, "https://"+addr+"/payload.bin", nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Range", "bytes=0-0")
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if cr := resp.Header.Get("Content-Range"); cr != "" {
		// Format: "bytes 0-0/12345"
		if i := strings.LastIndex(cr, "/"); i >= 0 {
			if total, err := strconv.ParseInt(strings.TrimSpace(cr[i+1:]), 10, 64); err == nil {
				return total, nil
			}
		}
	}
	if resp.StatusCode == http.StatusOK && resp.ContentLength >= 0 {
		return resp.ContentLength, nil
	}
	return 0, fmt.Errorf("could not determine payload size (status %d, no Content-Range); is /payload.bin served with range support?", resp.StatusCode)
}

func summarizePct(latencies []time.Duration) pct {
	if len(latencies) == 0 {
		return pct{}
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	n := len(latencies)
	return pct{
		Min: msOf(latencies[0]),
		P50: msOf(percentile(latencies, 0.50)),
		P95: msOf(percentile(latencies, 0.95)),
		P99: msOf(percentile(latencies, 0.99)),
		Max: msOf(latencies[n-1]),
	}
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

func writeResult(o output, out string) {
	data, err := json.MarshalIndent(o, "", "  ")
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
