# Perf Report — opentelemetry-collector (core)

Branch: `perf/opt-20261030`
Base: `upstream/main` at `9afdf701f` (synced 2026-10-30, fork `Narayan201120` + local `main` fast-forwarded, then pushed to `origin/main`)
Go: `go1.27.1 windows/amd64` (repo requires `go 1.26.0`)
Target env: Windows 11, AMD Ryzen 5 5600H, local dev. No throttling yet. Constrained runs TODO.
Primary metrics: wall ns/op, B/op, allocs/op for queue offer + pdata proto; binary size + build time.

## Before (baseline, no changes)

Binary (dev build, no strip):
- `cmd/otelcorecol`: `go build -trimpath -tags grpcnotrace` → `bin/otelcorecol_baseline.exe` 51,263,488 bytes (~48.9 MiB)
- Official builder default adds `-ldflags="-s -w"` (strip). Our baseline omits it on purpose to show strip win later.

Micro (short benchtime, 1-3 counts, Windows, Ryzen 5 5600H):
- `pdata/ptrace BenchmarkTracesToProto2k`: ~85-103k ns/op, ~82k B/op, 2 allocs/op
- `pdata/plog BenchmarkLogsToProto2k`: ~55k ns/op, ~41k B/op, 2 allocs/op
- `pdata/pmetric BenchmarkMetricsToProto2k`: ~105k ns/op, ~90k B/op, 2 allocs/op
- `pdata/ptrace BenchmarkTracesFromProto2k`: ~332-387k ns/op, ~496k B/op, 4019 allocs/op
- `exporterhelper/internal/queue BenchmarkMemoryQueueWaitForResult` (100 offers/iter): ~138-167k ns/op per 100 offers (~1.4-1.7us/offer), 6405 B/op, 100 allocs/op (1 alloc/offer from linked-list node)

Notes:
- `ToProto` already 2 allocs, near optimal.
- `FromProto` 4019 allocs dominates ingest, but fix needs proto/pdata redesign, out of safe scope.
- Queue 1 alloc/offer is the clean lever, but naive node pooling is unsafe with `waitForResult` abandon (Offer holds `*node` across wait, Read pops early, reuse would corrupt `queued/abandoned`). Documented, not attempted.
- `obsQueue.Offer` calls `req.ItemsCount()` unconditionally (walks spans via `SpanCount()` on first call, cached after). When telemetry disabled (`RecordIntFunc==nil`), this walk is pure overhead. Same for tracer Start/End on nop. This is iteration 1 target.

Profile:
- `go test -cpuprofile` failed on Windows in this env (profile file not written, `pprof` no source). Fallback: `benchstat`-style manual medians + `go test -benchmem`. Native pprof retry TODO on Linux/CI.
- Top hotspots by code inspection: `pdata/internal/proto` marshal/unmarshal, `fanoutconsumer` clone (`CopyTo`), `memory_queue` Offer/Read lock + node alloc, `obsQueue` ItemsCount + tracer, `queuebatch` merge/split.

Critical flows (regression checklist):
- otelcorecol startup, graph Build/StartAll/ShutdownAll
- receiver OTLP → ptrace/plog/pmetric → fanout → batch → queue → exporter OTLP
- wait_for_result true/false, blockOnOverflow, persistent vs memory queue
- profiles signal via xprocessorhelper (recent obsreport fix)

## Iteration log

### 0 — Sync only, no code change
- `git fetch upstream --prune; git fetch origin --prune`
- `git merge --ff-only upstream/main` (adbedb4fd → 9afdf701f, 12 files, queue + xprocessorhelper)
- `git push origin main`
- Branch `perf/opt-20261030` created.

### 1 — Skip `ItemsCount()` + enqueue metrics when telemetry disabled — KEPT
- File: `exporter/exporterhelper/internal/queue/obs_queue.go`
- Why: `ItemsCount()` walks payload (`SpanCount`, etc., cached after first call). `RecordInt` no-ops when `RecordIntFunc==nil`, so skipping the count preserves output.
- Safety: guard on `RecordIntFunc != nil` only, no `ShouldRecord` gate. Existing injected metrics (only `RecordIntFunc` set, no `ShouldRecordFunc`) still record. Tracer Start/End untouched.
- Bench: new `exporter/exporterhelper/internal/queue/obs_queue_perf_bench_test.go` `BenchmarkObsQueueNopExpensive` (expensive 2k-item `ItemsCount`, nop `ObsMetrics{}`).
  - Before (old `obs_queue.go`): 639–1620 ns/op (median ~790), 72 B/op, 3 allocs/op, `ItemsCount` calls=1
  - After (patched): 71–88 ns/op, 72 B/op, 3 allocs/op, `ItemsCount` calls=0
  - Delta: latency -89% (exceeds 50% target for this workload), allocs unchanged, B/op unchanged
- Tests: `go test ./internal/queue -count=1` PASS (10.8s), `go test ./...` in `exporter/exporterhelper` PASS, `go vet ./internal/queue/...` clean. Existing `TestObsQueue*` all PASS, including failure paths (error still records when enabled).
- Existing `BenchmarkMemoryQueueWaitForResult` unaffected as expected (tests `memoryQueue` directly, bypasses `obsQueue`).
- Status: KEPT, commit next.

## Size breakdown (TODO)
- `go list -f '{{.ImportPath}} {{.Deps}}'` + `gonum, k8s.io, prometheus, gopsutil, klauspost/compress` heavy transitives noted in discovery. No removals yet, need unused proof.
- Builder already `-trimpath -s -w -tags grpcnotrace`, `CGO_ENABLED=0`. No PGO/LTO in repo.

## Remaining opportunities
- PGO profile for otelcorecol, `-ldflags="-s -w"` verify in CI, duplicate `backoff/v5+v7`, `yaml/v2+v3`, `json-iterator` audit (needs static + dynamic proof, not done).
- `asyncQueue.Offer` span events guarded by `IsRecording()`, `memory_queue` node pool with safe lifetime (needs abandon redesign), `fanoutconsumer` read-only fast path already optimal.
- Persistent queue serialize/deserialize + disk I/O, batch merge/split copies.

## Risks / manual QA
- Any queue/telemetry change must pass `exporterhelper`, `queuebatchprocessor`, `service` graph tests + `race`.
- Do not touch `protected areas`: none named, so none.
