#!/usr/bin/env bash
# ==============================================================================
# Destructive Drive Health Test (v1)
# ==============================================================================
# WARNING: This script OVERWRITES the block devices you specify.
# Run ONLY after you've wiped/reformatted and confirmed no data is needed.
#
# What it does per target disk (e.g., /dev/nvme0n1, /dev/sda):
#   1) Pre-snapshot SMART/NVMe health
#   2) (Optional) blkdiscard/TRIM (SSD/NVMe) if ENABLE_BLKDISCARD=1
#   3) badblocks -wsv (1 pass, 4 patterns) full-surface write+verify
#   4) fio random write+verify sample (time-based)
#   5) SMART LONG self-test (blocking until complete), then post-snapshot
#   6) Append detailed results to a CSV
#
# Usage:
#   sudo TARGET_DISKS="/dev/nvme0n1 /dev/sda" ./destructive_drive_test.sh
#
# Optional env:
#   ENABLE_BLKDISCARD=1     # run blkdiscard before tests (destructive)
#   BADBLOCKS_PASSES=1      # passes for badblocks -w (default 1; higher = longer)
#   FIO_RUNTIME=180         # seconds for fio write+verify (default 180)
#   CSV_PREFIX="drive_health"
#
# Hard safety checks:
#   - Refuses to run unless TARGET_DISKS is set
#   - Refuses if a target is mounted or is the root/boot disk
#   - Interactive confirmation prompt ("YES") unless FORCE=1
# ==============================================================================

set -Eeuo pipefail

# --- Config ---
ENABLE_BLKDISCARD="${ENABLE_BLKDISCARD:-0}"
BADBLOCKS_PASSES="${BADBLOCKS_PASSES:-1}"
FIO_RUNTIME="${FIO_RUNTIME:-180}"   # seconds
CSV_PREFIX="${CSV_PREFIX:-drive_health}"
FORCE="${FORCE:-0}"

# --- Target disks (space-separated block devices) ---
TARGET_DISKS="${TARGET_DISKS:-}"

if [ -z "${TARGET_DISKS}" ]; then
  echo "ERROR: Set TARGET_DISKS, e.g.:"
  echo "  sudo TARGET_DISKS=\"/dev/nvme0n1 /dev/sda\" $0"
  exit 1
fi

# --- Output CSV ---
HOSTNAME_ID="$(hostname || echo unknown-host)"
TIMESTAMP="$(date +"%Y-%m-%d_%H%M%S")"
OUTPUT_CSV="${CSV_PREFIX}_${HOSTNAME_ID}_${TIMESTAMP}.csv"
echo "System_Identifier,Device,Phase,Details,Test,Result,Notes" > "$OUTPUT_CSV"

# --- Helpers ---
have(){ command -v "$1" >/dev/null 2>&1; }
csv_escape(){ local s="${1:-}"; s="${s//\"/\"\"}"; printf '%s' "$s"; }
row(){ # 1:Device 2:Phase 3:Details 4:Test 5:Result 6:Notes
  printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
    "$(csv_escape "$HOSTNAME_ID")" \
    "$(csv_escape "${1:-}")" \
    "$(csv_escape "${2:-}")" \
    "$(csv_escape "${3:-}")" \
    "$(csv_escape "${4:-}")" \
    "$(csv_escape "${5:-}")" \
    "$(csv_escape "${6:-}")" >> "$OUTPUT_CSV"
}

# --- Safety checks ---
ROOT_DEV="$(findmnt -no SOURCE / || true)"
BOOT_DEV="$(findmnt -no SOURCE /boot 2>/dev/null || true)"
for dev in $TARGET_DISKS; do
  # normalize symlink to real dev (optional)
  REAL="$(readlink -f "$dev" || echo "$dev")"
  # Must be a block device
  if [ ! -b "$REAL" ]; then
    echo "ERROR: $REAL is not a block device."
    exit 1
  fi
  # Must not be mounted anywhere
  if lsblk -no MOUNTPOINT "$REAL" | grep -q .; then
    echo "ERROR: $REAL appears to be mounted. Unmount all partitions first."
    lsblk "$REAL"
    exit 1
  fi
  # Must not be the current root or boot device (or their parents)
  if [[ "$ROOT_DEV" == "$REAL"* ]] || [[ "$BOOT_DEV" == "$REAL"* ]]; then
    echo "ERROR: $REAL looks like the OS/root/boot disk. Refusing."
    lsblk "$REAL"
    exit 1
  fi
done

echo "About to DESTRUCTIVELY test these devices: $TARGET_DISKS"
echo "CSV log: $OUTPUT_CSV"
if [ "$FORCE" != "1" ]; then
  read -r -p "Type YES to proceed: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 1; }
fi

# --- Tool presence summary ---
MISSING=()
for bin in smartctl badblocks fio lsblk nvme; do have "$bin" || MISSING+=("$bin"); done
row "ALL" "Setup" "Missing tools: ${MISSING[*]:-none}" "preflight" "OK" ""

# --- Functions per-device ---
smart_snapshot() {
  local dev="$1" when="$2"
  local out
  if [[ "$(basename "$dev")" == nvme* ]] && have smartctl; then
    out="$(smartctl -a -d nvme "$dev" 2>/dev/null || true)"
  elif have smartctl; then
    out="$(smartctl -a "$dev" 2>/dev/null || true)"
  fi
  # Extract some key lines (best-effort)
  local lines="$(printf '%s\n' "$out" | awk '
    /Model|Device Model|Serial Number|Firmware|Power_On_Hours|Reallocated|Media_Wearout|Percent_Lifetime|Media and Data Integrity Errors|CRC_Error_Count|Temperature/ {print}
  ')"
  [ -z "$lines" ] && lines="(no SMART detail)"
  row "$dev" "$when" "$(printf '%s' "$lines")" "smartctl -a" "Collected" ""
}

nvme_health() {
  local dev="$1" when="$2"
  if [[ "$(basename "$dev")" == nvme* ]] && have nvme; then
    local sm="$(nvme smart-log "$dev" 2>/dev/null || true)"
    local el="$(nvme error-log "$dev" 2>/dev/null || true)"
    local pick="$(printf '%s\n' "$sm" | awk -F: '/temperature|critical_warning|media_errors|num_err_log_entries|percentage_used|power_on_hours/ {gsub(/^[ \t]+/,"",$2); print $1":"$2}')"
    row "$dev" "$when" "$(printf 'SMART:%s ; Errors:%s' "$pick" "$(echo "$el" | wc -l)")" "nvme-cli" "Collected" ""
  fi
}

maybe_blkdiscard() {
  local dev="$1"
  if [ "$ENABLE_BLKDISCARD" = "1" ] && have blkdiscard; then
    if blkdiscard -f "$dev" 2>/dev/null; then
      row "$dev" "Prepare" "blkdiscard successful" "blkdiscard" "OK" ""
    else
      row "$dev" "Prepare" "blkdiscard failed/unsupported" "blkdiscard" "Skipped" ""
    fi
  else
    row "$dev" "Prepare" "blkdiscard disabled" "blkdiscard" "Skipped" ""
  fi
}

run_badblocks() {
  local dev="$1"
  # One pass (-p 1) of write-mode (-w), verbose (-v), show progress (-s)
  # badblocks default write patterns: 0xAA, 0x55, 0xFF, 0x00 (per pass)
  if badblocks -wsv -p "$BADBLOCKS_PASSES" "$dev" >"badblocks_$(basename "$dev").log" 2>&1; then
    row "$dev" "Surface" "Full write+verify (badblocks) p=$BADBLOCKS_PASSES" "badblocks -wsv" "Pass" "badblocks_$(basename "$dev").log"
  else
    row "$dev" "Surface" "Errors detected; see log" "badblocks -wsv" "FAIL" "badblocks_$(basename "$dev").log"
  fi
}

run_fio_verify() {
  local dev="$1"
  # Random write + verify on raw device; confined by time (FIO_RUNTIME)
  # We use crc32c verification during write.
  if fio --name=randwrv --filename="$dev" --rw=randwrite --bs=4k --iodepth=32 \
         --ioengine=libaio --direct=1 --time_based --runtime="$FIO_RUNTIME" \
         --numjobs=1 --group_reporting --verify=crc32c --do_verify=1 \
         >"fio_$(basename "$dev").log" 2>&1; then
    row "$dev" "Random" "randwrite+verify 4k iodepth=32 ${FIO_RUNTIME}s" "fio" "Pass" "fio_$(basename "$dev").log"
  else
    row "$dev" "Random" "Verification or I/O error" "fio" "FAIL" "fio_$(basename "$dev").log"
  fi
}

run_smart_long() {
  local dev="$1"
  local started=0
  if [[ "$(basename "$dev")" == nvme* ]] && have smartctl; then
    smartctl -t long -d nvme "$dev" >/dev/null 2>&1 && started=1
  elif have smartctl; then
    smartctl -t long "$dev" >/dev/null 2>&1 && started=1
  fi
  if [ "$started" -ne 1 ]; then
    row "$dev" "SMART" "Unable to start long test" "smartctl -t long" "Skipped" ""
    return
  fi
  row "$dev" "SMART" "Long test started" "smartctl -t long" "Running" ""

  # Poll until finished (parses status text)
  while :; do
    sleep 60
    local st
    if [[ "$(basename "$dev")" == nvme* ]]; then
      st="$(smartctl -c -d nvme "$dev" 2>/dev/null | grep -i 'Self-test' || true)"
    else
      st="$(smartctl -c "$dev" 2>/dev/null | grep -i 'Self-test' || true)"
    fi
    # When no "in progress" line remains, assume finished
    if ! echo "$st" | grep -qi 'in progress'; then
      break
    fi
  done
  # Fetch last result
  local rep
  if [[ "$(basename "$dev")" == nvme* ]]; then
    rep="$(smartctl -a -d nvme "$dev" 2>/dev/null || true)"
  else
    rep="$(smartctl -a "$dev" 2>/dev/null || true)"
  fi
  local last="$(printf '%s\n' "$rep" | awk '/Self-test execution status|Self-test Log|# 1 /{print}' | head -n 10 | tr '\n' '; ')"
  row "$dev" "SMART" "Long test completed" "smartctl -a" "${last:-Completed}" ""
}

# --- Main loop ---
for dev in $TARGET_DISKS; do
  dev="$(readlink -f "$dev" || echo "$dev")"
  DESC="$(lsblk -dn -o MODEL,SIZE "$dev" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')"
  row "$dev" "Identify" "$DESC" "lsblk" "OK" ""

  smart_snapshot "$dev" "Pre"
  nvme_health "$dev" "Pre"

  maybe_blkdiscard "$dev"
  run_badblocks "$dev"
  run_fio_verify "$dev"

  run_smart_long "$dev"

  smart_snapshot "$dev" "Post"
  nvme_health "$dev" "Post"
done

echo "------------------------------------------------------------------------------"
echo "DESTRUCTIVE tests complete. CSV saved to: $OUTPUT_CSV"
echo "Per-device logs: badblocks_*.log, fio_*.log"
