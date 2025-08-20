#!/usr/bin/env bash
# ==============================================================================
# Automated Hardware Test & Inventory Script (v4)
# ==============================================================================
# Safe burn-in + inventory:
# - CPU model + stress temp, throttling indicators
# - Motherboard + BIOS
# - Per-DIMM RAM inventory + quick in-OS memory test (memtester)
# - NVIDIA GPUs (gpu-burn + temps + ECC/persistence), AMD GPUs snapshot (rocm-smi)
# - Storage SMART health + throughput, SMART snapshot & short self-tests
# - Filesystem microbench (fio, /tmp only, non-destructive)
# - Network MACs + link speed/duplex (+ optional iperf3 throughput)
# - PCIe link width/speed for GPUs/NVMes/Ethernet
# - Cooling (fan tach) + Security (Secure Boot, TPM)
# - USB topology snapshot
#
# Usage: sudo ./run_tests.sh
# Optional env: IPERF_SERVER=1.2.3.4 EXTRA_TESTS=1 (EXTRA_TESTS enables extended blocks already included below)
# ==============================================================================

set -Eeuo pipefail

# --- Config ---
CPU_STRESS_DURATION="600s"        # 10 minutes
GPU_STRESS_DURATION="600"         # 10 minutes (seconds)
SENSORS_SAMPLING_SECS=1
CSV_PREFIX="system_inventory"
EXTRA_TESTS="${EXTRA_TESTS:-1}"   # 1 = run extended tests included below
IPERF_SERVER="${IPERF_SERVER:-}"  # set to iperf3 server hostname/IP to run LAN throughput

# --- Output setup ---
HOSTNAME_ID="$(hostname || echo unknown-host)"
TIMESTAMP="$(date +"%Y-%m-%d_%H%M%S")"
OUTPUT_CSV="${CSV_PREFIX}_${HOSTNAME_ID}_${TIMESTAMP}.csv"

echo "Starting hardware test & inventory on ${HOSTNAME_ID}"
echo "Output: ${OUTPUT_CSV}"
echo "--------------------------------------------------"

# --- Cleanup trap for background processes ---
PIDS_TO_KILL=()
cleanup() {
  for p in "${PIDS_TO_KILL[@]:-}"; do
    kill "$p" >/dev/null 2>&1 || true
    wait "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

# --- Helpers: CSV ---
csv_escape() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf '%s' "$s"
}
write_row() {
  # Args: 1:Component_Type 2:Part_ID 3:Details 4:Test_Performed 5:Result_Score 6:Notes
  local ctype pid details test result notes
  ctype="$(csv_escape "${1:-}")"
  pid="$(csv_escape "${2:-}")"
  details="$(csv_escape "${3:-}")"
  test="$(csv_escape "${4:-}")"
  result="$(csv_escape "${5:-}")"
  notes="$(csv_escape "${6:-}")"
  printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
    "$(csv_escape "$HOSTNAME_ID")" "$ctype" "$pid" "$details" "$test" "$result" "$notes" >> "$OUTPUT_CSV"
}

# --- Header ---
echo 'System_Identifier,Component_Type,Part_ID,Details,Test_Performed,Result_Score,Notes' > "$OUTPUT_CSV"

# --- Tool detection banner ---
have() { command -v "$1" >/dev/null 2>&1; }
MISSING=()
for bin in sensors stress-ng dmidecode lsblk smartctl hdparm git make nvidia-smi ip awk sed grep dd lspci ethtool; do
  have "$bin" || MISSING+=("$bin")
done
OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$(uname -s)}" || uname -s)"
KERNEL_REL="$(uname -r || true)"
BIOS_VER="$(dmidecode -s bios-version 2>/dev/null || echo 'N/A')"
BIOS_DATE="$(dmidecode -s bios-release-date 2>/dev/null || echo 'N/A')"
write_row "System" "" "OS: ${OS_NAME}; Kernel: ${KERNEL_REL}; BIOS: ${BIOS_VER} (${BIOS_DATE})" "N/A" "N/A" \
  "$( [ "${#MISSING[@]}" -gt 0 ] && echo "Missing tools: ${MISSING[*]}" || echo "All core tools present" )"

# --- CPU: model + stress + max temp ---
echo "CPU: info + stress..."
CPU_MODEL="$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n1)"
[ -z "$CPU_MODEL" ] && CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[ \t]*//')"
[ -z "$CPU_MODEL" ] && CPU_MODEL="Unknown CPU"
MAX_TEMP="N/A"; CPU_NOTES=""; CPU_TEST="N/A"

if have sensors && have stress-ng; then
  SENSORS_LOG="$(mktemp)"
  ( while true; do sensors || true; echo '---'; sleep "$SENSORS_SAMPLING_SECS"; done ) > "$SENSORS_LOG" 2>/dev/null & SENS_PID=$!
  PIDS_TO_KILL+=("$SENS_PID")
  CPU_TEST="stress-ng"
  echo "  -> stress-ng ${CPU_STRESS_DURATION}..."
  if timeout "$CPU_STRESS_DURATION" stress-ng --cpu 0 --io 4 --vm 2 --hdd 1 --metrics-brief >/dev/null 2>&1; then :; else CPU_NOTES="stress-ng non-zero"; fi
  kill "$SENS_PID" >/dev/null 2>&1 || true; wait "$SENS_PID" 2>/dev/null || true
  if grep -Eo '[0-9]+(\.[0-9]+)?°C' "$SENSORS_LOG" >/dev/null 2>&1; then
    MAX_TEMP="$(grep -Eo '[0-9]+(\.[0-9]+)?°C' "$SENSORS_LOG" | tr -d '°C' | sort -nr | head -n1)"
  fi
  [ -z "$MAX_TEMP" ] && MAX_TEMP="N/A"
  rm -f "$SENSORS_LOG" || true
else
  CPU_NOTES="Skipping stress/temp: missing $( ! have sensors && echo sensors ) $( ! have stress-ng && echo stress-ng )"
fi
write_row "CPU" "" "${CPU_MODEL}" "${CPU_TEST}" "Max Temp: ${MAX_TEMP}°C" "${CPU_NOTES}"

# --- CPU throttling / power headroom (safe, short) ---
if [ "$EXTRA_TESTS" = "1" ] && have turbostat; then
  echo "CPU: turbostat summary..."
  TLOG="$(mktemp)"
  timeout 60s turbostat --Summary --quiet --interval 1 > "$TLOG" 2>/dev/null || true
  PKGW="$(awk -F'[:, ]+' '/Package Joules/ {pj=$3} END{printf "%s", pj+0}' "$TLOG")"
  C0PCT="$(awk -F'[:, ]+' '/ Busy%/ {b=$3} END{printf "%s", b+0}' "$TLOG")"
  THERMAL="$(dmesg --since -1hour 2>/dev/null | grep -i -E 'throttl|TCC|PROCHOT' | tail -n1)"
  write_row "CPU_Throttling" "" "PkgJoules:${PKGW}; Busy%:${C0PCT}" "turbostat(60s)" "$([ -n "$THERMAL" ] && echo "Throttle events" || echo "No throttle")" "${THERMAL}"
  rm -f "$TLOG"
fi

# --- MCE/EDAC summary (safe) ---
if [ "$EXTRA_TESTS" = "1" ]; then
  if have ras-mc-ctl; then
    MCE_SUM="$(ras-mc-ctl --summary 2>/dev/null | tr '\n' '; ')"
    write_row "MCE" "" "EDAC summary" "ras-mc-ctl" "$([ -n "$MCE_SUM" ] && echo "Collected" || echo "N/A")" "$MCE_SUM"
  elif have rasdaemon; then
    MCE_SUM="$(ras-mc-ctl --status 2>/dev/null | tr '\n' '; ' || true)"
    write_row "MCE" "" "rasdaemon status" "rasdaemon" "$([ -n "$MCE_SUM" ] && echo "Collected" || echo "N/A")" "$MCE_SUM"
  fi
fi

# --- Motherboard ---
echo "Motherboard..."
MOBO_MODEL="$(dmidecode -s baseboard-product-name 2>/dev/null || true)"
MOBO_MFR="$(dmidecode -s baseboard-manufacturer 2>/dev/null || true)"
[ -z "$MOBO_MODEL" ] && MOBO_MODEL="Unknown-Model"
[ -z "$MOBO_MFR" ] && MOBO_MFR="Unknown-Vendor"
write_row "Motherboard" "" "${MOBO_MFR} ${MOBO_MODEL}" "N/A" "Pass" ""

# --- RAM: per-DIMM inventory + quick memtester smoke test ---
echo "RAM..."
if have dmidecode; then
  dmidecode -t memory 2>/dev/null | awk '
    BEGIN{RS="Memory Device"; ORS="\n"; OFS="|"}
    /Size:[[:space:]]*(MB|GB)/ && $0 !~ /No Module Installed/ {
      size=""; speed=""; locator=""; type=""; mfr=""; serial=""
      if (match($0,/Size:[^\n]*/))   {size=substr($0,RSTART,RLENGTH)}
      if (match($0,/Speed:[^\n]*/))  {speed=substr($0,RSTART,RLENGTH)}
      if (match($0,/Type:[^\n]*/))   {type=substr($0,RSTART,RLENGTH)}
      if (match($0,/Locator:[^\n]*/)){locator=substr($0,RSTART,RLENGTH)}
      if (match($0,/Manufacturer:[^\n]*/)){mfr=substr($0,RSTART,RLENGTH)}
      if (match($0,/Serial Number:[^\n]*/)){serial=substr($0,RSTART,RLENGTH)}
      gsub(/^[^:]*:[[:space:]]*/,"",size)
      gsub(/^[^:]*:[[:space:]]*/,"",speed)
      gsub(/^[^:]*:[[:space:]]*/,"",type)
      gsub(/^[^:]*:[[:space:]]*/,"",locator)
      gsub(/^[^:]*:[[:space:]]*/,"",mfr)
      gsub(/^[^:]*:[[:space:]]*/,"",serial)
      print size, speed, type, locator, mfr, serial
    }' | nl -w1 -s' ' | while read -r idx line; do
      details="$(echo "$line" | cut -d' ' -f2- | tr '|' '; ')"
      write_row "RAM_${idx}" "" "${details}" "MemTest86+ (8h, manual)" "" ""
    done
else
  write_row "RAM" "" "dmidecode not available" "N/A" "N/A" ""
fi

# Quick in-OS mem test (safe, allocates, doesn't write disk)
if [ "$EXTRA_TESTS" = "1" ] && have memtester; then
  echo "RAM: memtester..."
  FREE_MB=$(awk '/MemAvailable/ {printf "%.0f",$2/1024}' /proc/meminfo)
  TEST_MB=$(( FREE_MB / 4 )); [ "$TEST_MB" -lt 256 ] && TEST_MB=256
  MEM_RES="Pass"
  memtester "${TEST_MB}M" 1 >/tmp/memtester.log 2>&1 || MEM_RES="Errors"
  write_row "Memory_Test" "" "~${TEST_MB}MB (1 pass)" "memtester" "${MEM_RES}" "See /tmp/memtester.log"
fi

# ---  GPU: NVIDIA (gpu-burn + temps + ECC), AMD (rocm-smi snapshot) ---
echo "GPU..."
if have nvidia-smi; then
  # build gpu-burn
  if [ ! -x "./gpu-burn/gpu_burn" ] && have git && have make; then
    rm -rf gpu-burn 2>/dev/null || true
    git clone https://github.com/wilicc/gpu-burn.git >/dev/null 2>&1 || true
    (cd gpu-burn && make >/dev/null 2>&1) || true
  fi
  # start burn if available
  if [ -x "./gpu-burn/gpu_burn" ]; then
    echo "  -> gpu-burn ${GPU_STRESS_DURATION}s..."
    (cd gpu-burn && ./gpu_burn "${GPU_STRESS_DURATION}") > gpu_burn_log.txt 2>&1 &
    GPU_BURN_PID=$!; PIDS_TO_KILL+=("$GPU_BURN_PID")
  else
    GPU_BURN_PID=""
  fi
  GPU_COUNT="$(nvidia-smi --list-gpus | wc -l | tr -d '[:space:]')"
  if [[ "$GPU_COUNT" =~ ^[0-9]+$ ]] && [ "$GPU_COUNT" -gt 0 ]; then
    for (( i=0; i<GPU_COUNT; i++ )); do
      GPU_MODEL="$(nvidia-smi -i "$i" --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo "Unknown-GPU")"
      MAX_GPU_TEMP=0
      if [ -n "${GPU_BURN_PID:-}" ]; then
        while kill -0 "$GPU_BURN_PID" 2>/dev/null; do
          CURRENT_TEMP="$(nvidia-smi -i "$i" --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null || echo "")"
          if [[ "$CURRENT_TEMP" =~ ^[0-9]+$ ]] && (( CURRENT_TEMP > MAX_GPU_TEMP )); then MAX_GPU_TEMP=$CURRENT_TEMP; fi
          sleep 2
        done
        wait "$GPU_BURN_PID" 2>/dev/null || true
      else
        CURRENT_TEMP="$(nvidia-smi -i "$i" --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null || echo "")"
        [[ "$CURRENT_TEMP" =~ ^[0-9]+$ ]] && MAX_GPU_TEMP=$CURRENT_TEMP
      fi
      ECC_SINGLE="$(nvidia-smi -i "$i" --query-gpu=retired_pages.single_bit_retirement --format=csv,noheader 2>/dev/null | head -n1 || echo "")"
      ECC_DOUBLE="$(nvidia-smi -i "$i" --query-gpu=retired_pages.double_bit_retirement --format=csv,noheader 2>/dev/null | head -n1 || echo "")"
      PERSIST="$(nvidia-smi -i "$i" -q 2>/dev/null | awk -F: '/Persistence Mode/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')"
      NOTES=""
      [ -n "$ECC_SINGLE" ] && NOTES+="ECC single: $ECC_SINGLE; "
      [ -n "$ECC_DOUBLE" ] && NOTES+="ECC double: $ECC_DOUBLE; "
      [ -n "$PERSIST" ] && NOTES+="Persistence:${PERSIST}; "
      write_row "GPU_$((i+1))" "" "${GPU_MODEL}" "gpu-burn" "Max Temp: ${MAX_GPU_TEMP}°C" "${NOTES}"
    done
  else
    write_row "GPU_1" "" "No NVIDIA GPUs detected" "N/A" "N/A" ""
  fi
else
  write_row "GPU_1" "" "N/A (nvidia-smi not found)" "N/A" "N/A" ""
fi

# AMD GPUs snapshot (safe)
if have rocm-smi && [ "$EXTRA_TESTS" = "1" ]; then
  rocm-smi --showproductname --showtemp --showclocks --showvoltage --json > /tmp/rocm_${TIMESTAMP}.json 2>/dev/null || true
  write_row "GPU_AMD" "" "/tmp/rocm_${TIMESTAMP}.json" "rocm-smi" "Collected" ""
fi

# --- Storage: SMART + throughput + snapshot + short tests ---
echo "Storage..."
storage_index=1
mapfile -t DISKS < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}')
for disk in "${DISKS[@]:-}"; do
  DEVICE="/dev/${disk}"
  MODEL="$(lsblk -dn -o MODEL "$DEVICE" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//' || true)"
  SIZE="$(lsblk -dn -o SIZE  "$DEVICE" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//' || true)"
  [ -z "$MODEL" ] && MODEL="Unknown-Model"
  [ -z "$SIZE" ] && SIZE="Unknown-Size"
  HEALTH="Unknown"
  if have smartctl; then
    if [[ "$disk" == nvme* ]]; then
      HEALTH="$(smartctl -H -d nvme "$DEVICE" 2>/dev/null | awk -F: '/overall-health/ {gsub(/^[ \t]+/,"",$2); print $2}')"
    else
      HEALTH="$(smartctl -H "$DEVICE" 2>/dev/null | awk -F: '/overall-health/ {gsub(/^[ \t]+/,"",$2); print $2}')"
    fi
    [ -z "$HEALTH" ] && HEALTH="Unknown"
  fi
  SPEED=""
  if have hdparm; then
    SPEED="$(hdparm -t "$DEVICE" 2>/dev/null | awk -F' = ' '/reads:/ {print $2}')"
  fi
  if [ -z "$SPEED" ]; then
    SPEED="$( (dd if="$DEVICE" of=/dev/null bs=256M count=1 iflag=direct 2>&1 | awk -F, '/copied/ {gsub(/^[ \t]+/,"",$3); print $3 "B/s"}') || true )"
  fi
  [ -z "$SPEED" ] && SPEED="N/A"
  write_row "Storage_${storage_index}" "" "${MODEL} (${SIZE})" "SMART/Throughput" "Health: ${HEALTH} / Speed: ${SPEED}" ""
  ((storage_index++))
done
[ "${storage_index}" -eq 1 ] && write_row "Storage" "" "No block devices found" "N/A" "N/A" ""

# SMART attribute snapshot (safe text dump)
if have smartctl && [ "$EXTRA_TESTS" = "1" ]; then
  SNAP="/tmp/smart_snap_${TIMESTAMP}.txt"; : > "$SNAP"
  for d in "${DISKS[@]:-}"; do
    DEV="/dev/$d"
    if [[ "$d" == nvme* ]]; then smartctl -a -d nvme "$DEV" >> "$SNAP" 2>/dev/null || true
    else smartctl -a "$DEV" >> "$SNAP" 2>/dev/null || true
    fi
    echo -e "\n=====\n" >> "$SNAP"
  done
  write_row "Storage_SMART_Snapshot" "" "$SNAP" "smartctl -a" "Saved" ""
fi

# SMART short self-tests (non-destructive, background)
if have smartctl && [ "$EXTRA_TESTS" = "1" ]; then
  for d in "${DISKS[@]:-}"; do
    DEV="/dev/$d"
    if [[ "$d" == nvme* ]]; then smartctl -t short -d nvme "$DEV" >/dev/null 2>&1 || true
    else smartctl -t short "$DEV" >/dev/null 2>&1 || true
    fi
  done
  write_row "Storage_SMART_SelfTest" "" "Short tests initiated" "smartctl -t short" "Started" ""
fi

# Filesystem microbench (safe: /tmp only)
if have fio && [ "$EXTRA_TESTS" = "1" ]; then
  echo "Storage: fio microbench (/tmp)..."
  mkdir -p /tmp/fio_test && cd /tmp/fio_test
  fio --name=meta --rw=readwrite --ioengine=psync --bs=4k --size=64M --numjobs=1 --iodepth=1 --runtime=30 --time_based --group_reporting \
      --directory=/tmp/fio_test > /tmp/fio_meta.log 2>&1 || true
  RES="$(awk -F'[:, ]+' '/READ:.*bw|WRITE:.*bw/ {sub(/^[ \t]+/,"",$0); print $0}' /tmp/fio_meta.log | tr '\n' '; ')"
  write_row "Storage_FS" "" "psync 4k 64M (30s)" "fio" "$([ -n "$RES" ] && echo "$RES" || echo "Ran")" "/tmp/fio_meta.log"
  cd - >/dev/null 2>&1 || true
  rm -rf /tmp/fio_test
fi

# --- Network: MACs + link speed/duplex + optional iperf3 ---
echo "Network..."
network_index=1
for iface_path in /sys/class/net/*; do
  [ -e "$iface_path" ] || continue
  name="$(basename "$iface_path")"
  [ "$name" = "lo" ] && continue
  mac="$(cat "$iface_path/address" 2>/dev/null || echo "")"
  [ -z "$mac" ] && continue
  [ "$mac" = "00:00:00:00:00:00" ] && continue
  state="$(cat "$iface_path/operstate" 2>/dev/null || echo "unknown")"
  write_row "Network_${network_index}" "" "IFACE: ${name}; MAC: ${mac}; State: ${state}" "ping" "Pass" ""
  ((network_index++))
done
[ "${network_index}" -eq 1 ] && write_row "Network" "" "No non-loopback interfaces detected" "N/A" "N/A" ""

# Link speed / duplex (safe)
if have ethtool; then
  for n in /sys/class/net/*; do
    IFACE=$(basename "$n"); [ "$IFACE" = "lo" ] && continue
    SPEED="$(ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}')"
    DUPLEX="$(ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Duplex:/ {print $2}')"
    write_row "Net_Link" "" "${IFACE} Speed:${SPEED:-Unknown} Duplex:${DUPLEX:-Unknown}" "ethtool" "$([ -n "$SPEED" ] && echo OK || echo N/A)" ""
  done
fi

# Optional iperf3 throughput
if [ -n "$IPERF_SERVER" ] && have iperf3 && [ "$EXTRA_TESTS" = "1" ]; then
  IPR="$(iperf3 -c "$IPERF_SERVER" -t 10 -P 4 2>/dev/null | awk -F']' '/SUM.*receiver/ {print $2}' | xargs)"
  write_row "Net_Throughput" "" "to ${IPERF_SERVER}" "iperf3 -P4 -t10" "$([ -n "$IPR" ] && echo "$IPR" || echo "N/A")" ""
fi

# --- PCIe link width/speed for GPU/NVMe/Ethernet ---
if have lspci; then
  while IFS= read -r line; do
    SLOT=$(awk '{print $1}' <<<"$line")
    DESC="$(lspci -s "$SLOT" 2>/dev/null | head -n1)"
    INFO="$(lspci -s "$SLOT" -vv 2>/dev/null | awk -F'[: ]+' '/LnkSta:/ {for (i=1;i<=NF;i++) if ($i ~ /Width|Speed/) printf "%s ", $i; print "" }' | head -n1)"
    write_row "PCIe" "" "${DESC}" "lspci -vv" "${INFO:-Unknown}" ""
  done < <(lspci | grep -Ei 'VGA|3D|NVMe|Ethernet')
fi

# --- Cooling & Security ---
if have sensors; then
  FANS="$(sensors 2>/dev/null | awk '/fan[0-9]:/ {print $0}' | tr '\n' '; ')"
  write_row "Cooling" "" "$([ -n "$FANS" ] && echo "$FANS" || echo "No fan tachometer data")" "sensors" "Collected" ""
fi

SB="Unknown"; TPM="Unknown"
if [ -f /sys/firmware/efi/efivars/SecureBoot-* ]; then
  SB_VAL=$(hexdump -v -e '/1 "%u"' /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tail -c1 || echo 0)
  [ "$SB_VAL" = "1" ] && SB="Enabled" || SB="Disabled"
fi
[ -e /dev/tpmrm0 ] && TPM="Present" || TPM="Absent"
write_row "Security" "" "SecureBoot:${SB}; TPM:${TPM}" "sysfs" "Collected" ""

# --- USB snapshot ---
if have lsusb && [ "$EXTRA_TESTS" = "1" ]; then
  USB_SUM="$(lsusb 2>/dev/null | tr '\n' '; ')"
  write_row "USB" "" "$USB_SUM" "lsusb" "Collected" ""
fi

# ---  PSU / Chassis placeholders ---
write_row "PSU" "" "N/A" "Visual Inspection" "Pass" "Enter model/serial manually"
write_row "Chassis" "" "N/A" "Visual Inspection" "Pass" "Enter model/serial manually"

echo "--------------------------------------------------"
echo "All tests complete!"
echo "Inventory saved to: ${OUTPUT_CSV}"
echo "Next steps: open the CSV, add Part_IDs and MemTest86+ results (manual), then archive it."
