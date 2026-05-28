#!/usr/bin/env bash
# Full single-command local demo:
#   - kill any prior `sui start --with-faucet` localnet
#   - start a fresh one
#   - test-publish all three packages and register their Displays
#   - run the TS demo
#   - kill the localnet on exit (success or failure)
#
# Usage:
#   bash scripts/run-demo.sh                    # uses default `sui` on PATH
#   SUI=/path/to/sui bash scripts/run-demo.sh   # override sui binary

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUI="${SUI:-sui}"
LOCALNET_LOG="/tmp/sui-localnet-$$.log"

LOCAL_PID=""
cleanup() {
    if [[ -n "$LOCAL_PID" ]]; then
        echo
        echo "▶ stopping localnet (PID $LOCAL_PID)"
        kill "$LOCAL_PID" 2>/dev/null || true
        wait "$LOCAL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Kill any other lingering `sui start --with-faucet` from a prior run.
# Match against the binary path + the --with-faucet flag to avoid stomping
# on unrelated sui processes (sui-fork, indexers, etc.).
if pgrep -f 'sui start .*--with-faucet' >/dev/null; then
    echo "▶ killing prior localnet"
    pkill -f 'sui start .*--with-faucet' || true
    sleep 1
fi

echo "▶ starting localnet (log: $LOCALNET_LOG)"
"$SUI" start --force-regenesis --with-faucet > "$LOCALNET_LOG" 2>&1 &
LOCAL_PID=$!
# Wait for both the JSON-RPC port (9000) and the faucet port (9123).
for port in 9000 9123; do
    for _ in {1..60}; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
        sleep 0.5
    done
    if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
        echo "localnet port $port didn't come up; tail of log:"
        tail -20 "$LOCALNET_LOG"
        exit 1
    fi
done

echo "▶ switching sui client to local + faucet"
"$SUI" client switch --env local >/dev/null
"$SUI" client faucet >/dev/null
# Faucet credits are async; give them a beat to land before publish.
sleep 2

echo "▶ test-publish"
SETUP_OUT=$(SUI="$SUI" bash "$REPO_ROOT/scripts/test-publish.sh")
printf '%s\n' "$SETUP_OUT"

REGISTRY_ID=$(printf '%s\n' "$SETUP_OUT" \
    | awk '/^Registry shared object:/ {print $NF; exit}')
if [[ -z "$REGISTRY_ID" ]]; then
    echo "could not extract REGISTRY_ID from test-publish output" >&2
    exit 1
fi

echo
echo "▶ demo"
REGISTRY_ID="$REGISTRY_ID" pnpm --dir "$REPO_ROOT/ts" demo

echo
echo "▶ done"
