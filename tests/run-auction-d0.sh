#!/usr/bin/env bash
# Same proof on a provisioned Linux host; this is not a Linux PASS by itself.
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_godot="${1:-godot}"
task_label="${2:-linux-debug}"
if [[ ! "$task_label" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,50}$ ]]; then
    echo 'Invalid D0 diagnostic label' >&2
    exit 1
fi
task_pack="${3:-}"
task_dir="$task_root/.godot/verification/auction-d0-$task_label"
mkdir -p -- "$task_dir/xdg"
task_args=(--headless --path "$task_root")
if [[ -n "$task_pack" ]]; then task_args+=(--main-pack "$task_pack"); fi
XDG_DATA_HOME="$task_dir/xdg" "$task_godot" "${task_args[@]}" --mode=world-server \
    res://tests/auction_sqlite_threads.tscn --d0-project-root="$task_root" --d0-directory="$task_dir" --quit-after 2400 \
    > "$task_dir.out.log" 2> "$task_dir.err.log"
if ! rg -q AUCTION_D0_OK "$task_dir.out.log" || \
   rg -q 'SCRIPT ERROR|Parse Error|Caller thread|database is locked|database table is locked|Object is being used by another thread' "$task_dir.out.log" "$task_dir.err.log"; then
    echo "Auction D0 failed: $task_dir.out.log / $task_dir.err.log" >&2
    exit 1
fi
rg 'AUCTION_D0_PLUGIN|AUCTION_D0_CONCURRENCY|AUCTION_D0_OK' "$task_dir.out.log"
echo "Auction D0 ($task_label): PASS"
