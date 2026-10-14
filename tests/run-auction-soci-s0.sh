#!/usr/bin/env bash
# Repeatable Linux diagnostic entry point; availability is not runtime PASS.
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_godot="${1:-godot}"
task_dir="$task_root/.godot/verification/auction-soci-s0-linux-debug"
python3 "$task_root/tests/prepare-auction-soci-s0.py" --fixture-directory "$task_dir"
mkdir -p -- "$task_dir/xdg"
XDG_DATA_HOME="$task_dir/xdg" "$task_godot" --headless --path "$task_root" --mode=world-server \
    res://tests/auction_soci_s0.tscn --s0-project-root="$task_root" --s0-directory="$task_dir" \
    > "$task_dir.out.log" 2> "$task_dir.err.log" &
task_pid=$!
task_library="$task_root/.godot/verification/soci-release/package/addons/godot_soci/bin/linux/godot_soci.linux.template_debug.x86_64.so"
task_loaded=false
for ((task_try=0; task_try<100; task_try++)); do
    if [[ -r "/proc/$task_pid/maps" ]] && grep -Fq -- "$task_library" "/proc/$task_pid/maps"; then task_loaded=true; break; fi
    if ! kill -0 "$task_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
task_exit=0
wait "$task_pid" || task_exit=$?
grep 'AUCTION_S0_' "$task_dir.out.log" || true
if [[ "$task_loaded" != true || "$task_exit" != 0 ]] || ! grep -q AUCTION_S0_OK "$task_dir.out.log" || \
   grep -Eq 'SCRIPT ERROR|Parse Error|Caller thread|database is locked|database table is locked|Object is being used by another thread' "$task_dir.out.log" "$task_dir.err.log"; then
    echo "Auction SOCI S0 failed: $task_dir.out.log / $task_dir.err.log" >&2
    exit 1
fi
sha256sum -- "$task_library"
echo 'Auction SOCI S0 Linux Debug: PASS'
