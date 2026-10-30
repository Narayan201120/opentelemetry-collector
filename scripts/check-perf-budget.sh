#!/usr/bin/env bash
# CI perf budget check. Fails if BenchmarkObsQueueNopExpensive exceeds perf-budget.yaml.
set -euo pipefail
MODDIR="exporter/exporterhelper"
echo "Running perf budget check..."
pushd "$MODDIR" >/dev/null
CGO_ENABLED=0 go test ./internal/queue -run=notests -bench='BenchmarkObsQueueNopExpensive' -benchtime=5000x -count=3 -benchmem 2>&1 | tee /tmp/perf-out.txt
# Extract worst ns/op (3rd column after name, e.g., "5000  78.46 ns/op")
worst=$(grep BenchmarkObsQueueNopExpensive /tmp/perf-out.txt | awk '{for(i=1;i<=NF;i++) if($i=="ns/op") print $(i-1)}' | sort -n | tail -1)
echo "Worst ns/op: $worst (budget 300)"
python3 -c "import sys; w=float('$worst'); sys.exit(0 if w<=300 else 1)" || { echo "PERF BUDGET EXCEEDED: $worst > 300 ns/op"; exit 1; }
echo "Perf budget OK."
popd >/dev/null
