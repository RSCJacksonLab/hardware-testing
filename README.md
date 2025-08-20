# Workstation Hardware Testing Protocol (v2)

This document is the field guide for validating workstation hardware during scheduled maintenance. It standardizes how we boot, prepare the environment, run automated scripts, and finalize results.

---

## Boot Media Setup

You will need **two USB drives**:

1. **USB Drive 1: MemTest86+ (bootable)**  
   - Used for overnight memory validation.  
   - Download from: [https://www.memtest.org/](https://www.memtest.org/)  
   - Write to USB using `Rufus`, `balenaEtcher`, or `dd`.

2. **USB Drive 2: Ubuntu 24.04 (Persistent Installation)**  
   - This is not just a live “Try Ubuntu” session; it must be installed persistently onto the USB drive so tools and drivers survive reboots.  
   - Use one USB stick to boot the Ubuntu ISO installer, and a second USB stick (≥32 GB recommended) as the **install target**.  
   - During installation, select the second USB as the destination.  
   - After installation, you can boot directly into Ubuntu from this persistent USB on any workstation.

---

## Testing Workflow

### Step 1: Memory (RAM) Validation (Manual)

- Boot from the **MemTest86+ USB**.  
- Run for **at least 8 hours (overnight)**.  
- Record results manually (photo of the results screen).  
- During final CSV completion, you will manually enter **Pass/Fail** for each RAM stick.

---

### Step 2: Automated Testing with Scripts

1. **Boot into Ubuntu (persistent USB):**
   - Insert the Ubuntu 24.04 persistent USB.
   - Boot from it.

2. **Clone testing repository:**
   ```bash
   git clone https://github.com/your-lab/hw-testing.git
   cd hw-testing

3. Setup environment:
```bash
sudo ./setup_env.sh
```

- installs all required packages (stress tools, SMART tools, GPU tools).
-If an NVIDIA GPU is detected, the script will install drivers; reboot if prompted.

4. Run main safe hardware test:
```bash
sudo ./run_tests.sh
```
- Generates a CSV inventory (e.g., system_inventory_HOSTNAME_YYYYMMDD.csv).

5. (Optional) Run destructive disk test (only on blank drives):
```bash
sudo TARGET_DISKS="/dev/sdX /dev/nvme0n1" ./destructive_drive_test.sh
```

- Only run after drives have been reformatted and contain no data.
- This test writes and verifies the entire disk surface.

**Warning:** the `destructive_drive_test.sh` will permanently **wipe and reformat** drives. Do not use it unless you are confident that it will not cause data loss. 

### Step 3: Finalize the Inventory Sheet
Open the generated CSV in LibreOffice Calc, Excel, Sheets, etc. and fill in:
- **Part_ID**: Assign unique asset/inventory IDs.
- **RAM Test Results**: Add Pass/Fail for each stick based on MemTest86+. 
- **Notes**: Any physical issues, damage, etc.

Archive this sheet for future reference. 

### Included Tests (and what to expect)
- **CPU Stress (stress-ng + sensors)**:
Stresses CPU, records maximum observed temperature.
Expected result: Max temp stays below thermal throttling (typically <95 °C).

- **CPU Throttling Check (turbostat)**: 
Detects if CPU throttles under load.
Expected result: No throttle events logged.

- **MCE / RAS Errors (rasdaemon/ras-mc-ctl)**:
Reports any corrected/uncorrected CPU or RAM errors.
Expected result: Zero errors.

- **RAM Quick Test (memtester)**:
Allocates ~25% of free RAM, runs a single-pass check.
Expected result: Pass (no errors).

- **GPU Stress (gpu-burn, NVIDIA only)**:
Loads each GPU, records max temperature.
Expected result: Max GPU temp <85 °C under sustained load. No crashes.

- **GPU Diagnostics (nvidia-smi / rocm-smi)**:
Collects ECC error counts, persistence mode, AMD clocks/temps.
Expected result: Zero ECC errors, normal clock speeds.

- **torage Health (smartctl)**:
Reads drive SMART health (overall status).
Expected result: “PASSED”.

- **blkdiscard (optional; destructive)**:
Resets SSD/NVMe to fresh state.

-**badblocks (write + verify; destructive)**:
Full-surface destructive write/read with patterns.
Expected result: No bad blocks reported.

- **fio random write+verify (destructive)**:
Time-bounded random write with CRC verification.
Expected result: Pass with no verification errors.

- **SMART Long Self-Test (destructive)**:
Firmware-managed full surface scan.
Expected result: Completed without error.

### Final Notes
- Always save the final CSV + logs to external storage before shutdown.
- **Ensure all essential data is backed up before running any tests, even those that are non-destructive. All HDD tests have a chance of inducing a fault in the drives.
- For destructive disk tests, triple check TARGET_DISKS to avoid overwriting system drives. **You are responsible for any loss of data caused by drive tests, make sure everything is backed up and safe.**.
