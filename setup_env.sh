#!/usr/bin/env bash
# ==============================================================================
# Hardware Test Environment Setup Script (Persistent Ubuntu USB)
# ==============================================================================
# Description:
#   Prepares a persistent Ubuntu 24.04 installation on USB for workstation
#   hardware testing. This installs all required tools, stress utilities,
#   and GPU drivers so that the system can run the automated testing scripts.
#
# Usage:
#   1. Boot from your PERSISTENT Ubuntu 24.04 USB drive.
#   2. Connect to the internet.
#   3. Save this script as "setup_env.sh".
#   4. Make it executable: chmod +x setup_env.sh
#   5. Run with sudo: sudo ./setup_env.sh
#   6. If NVIDIA drivers are installed, reboot and select the USB again.
#      Navigate back to your cloned repo and continue with run_tests.sh.
#
# Notes:
#   - This script is safe to run multiple times; it will skip installed packages.
#   - Ensure persistence is enabled; otherwise, tools and drivers will be lost
#     after reboot.
# ==============================================================================

set -Eeuo pipefail

echo "=== Starting Hardware Test Environment Setup ==="

# Enable Universe/Multiverse repos
echo "[1/6] Enabling repositories..."
sudo add-apt-repository -y universe
sudo add-apt-repository -y multiverse
sudo apt update -y

echo "[2/6] Installing core tools..."
sudo apt install -y \
  build-essential git make wget unzip curl \
  lm-sensors pciutils usbutils lshw hdparm smartmontools nvme-cli \
  stress-ng memtester fio ethtool iperf3 \
  dmidecode iproute2 rasdaemon \
  linux-tools-common

# turbostat for the running kernel
KREL="$(uname -r)"
sudo apt install -y "linux-tools-${KREL}" || true
sudo sensors-detect --auto || true

echo "[3/6] Developer bits for GPU testing..."
# gpu-burn will be built by the run_tests.sh script as needed.

echo "[4/6] NVIDIA driver install (if NVIDIA GPU present)..."
if lspci | grep -q "NVIDIA.*VGA"; then
  echo "NVIDIA GPU detected -> installing recommended driver..."
  sudo ubuntu-drivers autoinstall || sudo ubuntu-drivers install || true
  echo "If prompted, reboot is required to load NVIDIA kernel modules."
else
  echo "No NVIDIA GPU detected; skipping driver install."
fi

echo "[5/6] AMD GPU tools (if present)..."
if lspci | grep -qi "AMD/ATI.*VGA"; then
  sudo apt install -y rocm-smi rocm-smi-lib || true
fi

echo "[6/6] Quality-of-life tools..."
sudo apt install -y jq moreutils || true

echo "=== Setup complete ==="
echo "Next: reboot if NVIDIA drivers were installed, otherwise proceed directly to run_tests.sh."
