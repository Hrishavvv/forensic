#!/bin/bash

# ============================================================
#   FORENSIC DRIVE ANALYSER
#   Checks connected drives for filesystem corruption & malware
# ============================================================

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Log file ──────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_DIR="$HOME/forensic_reports"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/forensic_report_$TIMESTAMP.txt"

# ── Helper: print & log ───────────────────────────────────────
log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_raw() { echo "$1" | tee -a "$LOG_FILE"; }
separator() { log "${DIM}$(printf '─%.0s' {1..60})${RESET}"; }

# ── Dependency check ──────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in lsblk blkid fsck smartctl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    # ClamAV is optional but flagged
    if ! command -v clamscan &>/dev/null; then
        log "${YELLOW}⚠  ClamAV (clamscan) not found – virus scan will be skipped.${RESET}"
        log "${DIM}   Install with: sudo apt install clamav && sudo freshclam${RESET}"
        CLAM_AVAILABLE=false
    else
        CLAM_AVAILABLE=true
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log "${RED}✖  Missing required tools: ${missing[*]}${RESET}"
        log "   Install with: sudo apt install util-linux smartmontools"
        exit 1
    fi
}

# ── Banner ────────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
  ███████╗ ██████╗ ██████╗ ███████╗███╗   ██╗███████╗██╗ ██████╗
  ██╔════╝██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║██╔════╝
  █████╗  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║███████╗██║██║
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║╚██╗██║╚════██║██║██║
  ██║     ╚██████╔╝██║  ██║███████╗██║ ╚████║███████║██║╚██████╗
  ╚═╝      ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝╚══════╝╚═╝ ╚═════╝
EOF
    echo -e "${RESET}${BOLD}${BLUE}        Drive Corruption & Malware Forensic Analyser${RESET}"
    echo -e "${DIM}        $(date '+%A, %d %B %Y  %H:%M:%S')${RESET}"
    separator
    echo ""
}

# ── List drives ───────────────────────────────────────────────
list_drives() {
    log "${BOLD}${CYAN}▸ Detecting connected block devices…${RESET}"
    echo ""

    # Collect drives (exclude loop & ram devices)
    mapfile -t DRIVES < <(lsblk -dpno NAME,SIZE,TYPE,VENDOR,MODEL,TRAN 2>/dev/null \
        | grep -v 'loop\|ram' \
        | grep -E 'disk|rom')

    if [ ${#DRIVES[@]} -eq 0 ]; then
        log "${RED}✖  No drives detected. Ensure drives are connected.${RESET}"
        exit 1
    fi

    echo -e "${BOLD}  #   Device       Size    Type   Transport   Vendor / Model${RESET}"
    separator

    local idx=1
    DRIVE_PATHS=()
    for drive in "${DRIVES[@]}"; do
        local dev size type vendor model tran
        dev=$(echo "$drive" | awk '{print $1}')
        size=$(echo "$drive" | awk '{print $2}')
        type=$(echo "$drive" | awk '{print $3}')
        vendor=$(echo "$drive" | awk '{print $4}')
        model=$(echo "$drive" | awk '{print $5}')
        tran=$(echo "$drive" | awk '{print $6}')

        # Highlight USB drives
        local color=$RESET
        [[ "$tran" == "usb" ]] && color=$YELLOW

        printf "  ${BOLD}%-3s${RESET} ${color}%-12s %-7s %-6s %-11s %s %s${RESET}\n" \
            "$idx)" "$dev" "$size" "$type" "${tran:-N/A}" "$vendor" "$model"

        DRIVE_PATHS+=("$dev")
        ((idx++))
    done

    echo ""
}

# ── Drive selection ───────────────────────────────────────────
select_drive() {
    local total=${#DRIVE_PATHS[@]}
    while true; do
        echo -ne "${BOLD}${GREEN}▸ Select drive number to analyse [1-$total] (q to quit): ${RESET}"
        read -r choice

        [[ "$choice" == "q" || "$choice" == "Q" ]] && { log "Exited by user."; exit 0; }

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            SELECTED_DRIVE="${DRIVE_PATHS[$((choice-1))]}"
            log ""
            log "${BOLD}${CYAN}▸ Selected: ${YELLOW}$SELECTED_DRIVE${RESET}"
            break
        else
            echo -e "${RED}  Invalid selection. Please enter a number between 1 and $total.${RESET}"
        fi
    done
}

# ── Mount point check ─────────────────────────────────────────
check_mount_status() {
    log ""
    separator
    log "${BOLD}${BLUE}[1/5] MOUNT STATUS & PARTITION TABLE${RESET}"
    separator

    log "${CYAN}▸ Partitions on $SELECTED_DRIVE:${RESET}"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID "$SELECTED_DRIVE" 2>/dev/null \
        | tee -a "$LOG_FILE"

    echo ""
    log "${CYAN}▸ Filesystem type (blkid):${RESET}"
    blkid "$SELECTED_DRIVE"* 2>/dev/null | tee -a "$LOG_FILE" || \
        log "${DIM}  No blkid output (may need root).${RESET}"

    # Detect if drive/partitions are mounted
    MOUNTED_PARTS=$(lsblk -lno NAME,MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null \
        | awk '$2 != "" {print "/dev/"$1" → "$2}')
    if [ -n "$MOUNTED_PARTS" ]; then
        log ""
        log "${YELLOW}⚠  Mounted partitions detected:${RESET}"
        echo "$MOUNTED_PARTS" | tee -a "$LOG_FILE"
        log "${DIM}  Note: fsck cannot check mounted filesystems.${RESET}"
    else
        log "${GREEN}✔  No partitions are currently mounted.${RESET}"
    fi
}

# ── SMART health ──────────────────────────────────────────────
check_smart() {
    log ""
    separator
    log "${BOLD}${BLUE}[2/5] S.M.A.R.T. HEALTH CHECK${RESET}"
    separator

    if ! command -v smartctl &>/dev/null; then
        log "${YELLOW}⚠  smartctl not available – skipping SMART check.${RESET}"
        return
    fi

    log "${CYAN}▸ Running SMART health self-assessment…${RESET}"

    local smart_out
    smart_out=$(sudo smartctl -H "$SELECTED_DRIVE" 2>&1)
    echo "$smart_out" | tee -a "$LOG_FILE"

    if echo "$smart_out" | grep -q "PASSED"; then
        log "${GREEN}✔  SMART status: PASSED${RESET}"
    elif echo "$smart_out" | grep -q "FAILED"; then
        log "${RED}✖  SMART status: FAILED — drive may be failing!${RESET}"
    else
        log "${YELLOW}⚠  SMART status could not be determined (may need root or unsupported).${RESET}"
    fi

    log ""
    log "${CYAN}▸ Key SMART attributes:${RESET}"
    sudo smartctl -A "$SELECTED_DRIVE" 2>/dev/null \
        | grep -E "Reallocated|Pending|Uncorrectable|Power_On|Temperature|Seek_Error|Spin_Retry" \
        | tee -a "$LOG_FILE" \
        || log "${DIM}  Attributes unavailable.${RESET}"
}

# ── Filesystem corruption check ───────────────────────────────
check_filesystem() {
    log ""
    separator
    log "${BOLD}${BLUE}[3/5] FILESYSTEM INTEGRITY CHECK (fsck)${RESET}"
    separator

    # Get all partitions of selected drive
    mapfile -t PARTS < <(lsblk -lno NAME,TYPE "$SELECTED_DRIVE" 2>/dev/null \
        | awk '$2=="part"{print "/dev/"$1}')

    if [ ${#PARTS[@]} -eq 0 ]; then
        log "${YELLOW}⚠  No partitions found on $SELECTED_DRIVE — checking whole disk.${RESET}"
        PARTS=("$SELECTED_DRIVE")
    fi

    for part in "${PARTS[@]}"; do
        log "${CYAN}▸ Checking partition: $part${RESET}"

        # Skip if mounted
        if mount | grep -q "^$part "; then
            log "${YELLOW}  ⚠  $part is mounted — skipping (unmount first for full check).${RESET}"
            continue
        fi

        local fstype
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null)
        log "${DIM}  Filesystem type: ${fstype:-unknown}${RESET}"

        case "$fstype" in
            ext2|ext3|ext4)
                log "${CYAN}  Running e2fsck (dry-run, no changes)…${RESET}"
                sudo fsck.ext4 -n "$part" 2>&1 | tee -a "$LOG_FILE"
                ;;
            vfat|fat32|fat16)
                log "${CYAN}  Running fsck.vfat (dry-run)…${RESET}"
                sudo fsck.vfat -n "$part" 2>&1 | tee -a "$LOG_FILE"
                ;;
            ntfs)
                if command -v ntfsfix &>/dev/null; then
                    log "${CYAN}  Running ntfsfix (check only)…${RESET}"
                    sudo ntfsfix -n "$part" 2>&1 | tee -a "$LOG_FILE"
                else
                    log "${YELLOW}  ⚠  ntfsfix not found. Install: sudo apt install ntfs-3g${RESET}"
                fi
                ;;
            xfs)
                if command -v xfs_repair &>/dev/null; then
                    log "${CYAN}  Running xfs_repair (dry-run)…${RESET}"
                    sudo xfs_repair -n "$part" 2>&1 | tee -a "$LOG_FILE"
                else
                    log "${YELLOW}  ⚠  xfs_repair not found. Install: sudo apt install xfsprogs${RESET}"
                fi
                ;;
            "")
                log "${YELLOW}  ⚠  Could not detect filesystem type — skipping.${RESET}"
                ;;
            *)
                log "${DIM}  Unsupported fs type '$fstype' — skipping fsck.${RESET}"
                ;;
        esac

        echo "" | tee -a "$LOG_FILE"
    done
}

# ── Bad sector scan ───────────────────────────────────────────
check_bad_sectors() {
    log ""
    separator
    log "${BOLD}${BLUE}[4/5] BAD SECTOR SCAN (badblocks – read-only)${RESET}"
    separator

    if ! command -v badblocks &>/dev/null; then
        log "${YELLOW}⚠  badblocks not found – skipping. Install: sudo apt install e2fsprogs${RESET}"
        return
    fi

    echo -ne "${BOLD}${GREEN}▸ Run bad sector scan? This may take several minutes. [y/N]: ${RESET}"
    read -r do_bad
    if [[ "$do_bad" =~ ^[Yy]$ ]]; then
        log "${CYAN}▸ Scanning for bad sectors on $SELECTED_DRIVE (read-only)…${RESET}"
        local bad_out
        bad_out=$(sudo badblocks -vs "$SELECTED_DRIVE" 2>&1)
        echo "$bad_out" | tee -a "$LOG_FILE"

        local bad_count
        bad_count=$(echo "$bad_out" | grep -c "bad block" || true)
        if [ "$bad_count" -gt 0 ]; then
            log "${RED}✖  Bad sectors detected: $bad_count block(s) affected!${RESET}"
        else
            log "${GREEN}✔  No bad sectors detected.${RESET}"
        fi
    else
        log "${DIM}  Bad sector scan skipped by user.${RESET}"
    fi
}

# ── Virus scan ────────────────────────────────────────────────
check_viruses() {
    log ""
    separator
    log "${BOLD}${BLUE}[5/5] MALWARE / VIRUS SCAN (ClamAV)${RESET}"
    separator

    if [ "$CLAM_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  ClamAV not installed — virus scan skipped.${RESET}"
        log "${DIM}   To enable: sudo apt install clamav && sudo freshclam${RESET}"
        return
    fi

    # Find a mount point to scan
    local scan_path
    scan_path=$(lsblk -lno MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null \
        | awk 'NF{print;exit}')

    if [ -z "$scan_path" ]; then
        echo -ne "${BOLD}${GREEN}▸ Drive not mounted. Enter mount point to scan (or press Enter to skip): ${RESET}"
        read -r scan_path
        if [ -z "$scan_path" ]; then
            log "${DIM}  Virus scan skipped — no mount point provided.${RESET}"
            return
        fi
    fi

    if [ ! -d "$scan_path" ]; then
        log "${YELLOW}⚠  Path '$scan_path' does not exist — skipping scan.${RESET}"
        return
    fi

    log "${CYAN}▸ Scanning $scan_path with ClamAV…${RESET}"
    log "${DIM}  (This may take a while for large drives)${RESET}"
    echo ""

    local clam_out
    clam_out=$(clamscan -r --bell -i "$scan_path" 2>&1)
    echo "$clam_out" | tee -a "$LOG_FILE"

    local infected
    infected=$(echo "$clam_out" | grep "^Infected files:" | awk '{print $3}')

    echo ""
    if [ "$infected" = "0" ]; then
        log "${GREEN}✔  No malware detected. Drive appears clean.${RESET}"
    else
        log "${RED}✖  INFECTED FILES FOUND: $infected — see report for details!${RESET}"
    fi
}

# ── Summary ───────────────────────────────────────────────────
show_summary() {
    log ""
    separator
    log "${BOLD}${MAGENTA}  FORENSIC ANALYSIS COMPLETE${RESET}"
    separator
    log "${DIM}  Drive analysed : ${YELLOW}$SELECTED_DRIVE${RESET}"
    log "${DIM}  Timestamp      : $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    log "${DIM}  Full report    : ${CYAN}$LOG_FILE${RESET}"
    separator
    echo ""
}

# ── Root warning ──────────────────────────────────────────────
root_warning() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}${BOLD}"
        echo "  ⚠  WARNING: Not running as root."
        echo "     Some checks (SMART, fsck, badblocks) require sudo."
        echo "     Re-run with: sudo $0"
        echo -e "${RESET}"
        sleep 2
    fi
}

# ── Main ──────────────────────────────────────────────────────
main() {
    show_banner
    root_warning
    check_deps

    # Write report header
    {
        echo "======================================================"
        echo " FORENSIC DRIVE ANALYSIS REPORT"
        echo " Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo " Host: $(hostname) | User: $(whoami)"
        echo "======================================================"
        echo ""
    } >> "$LOG_FILE"

    list_drives
    select_drive

    log ""
    log "${BOLD}${MAGENTA}▸ Starting forensic analysis of ${YELLOW}$SELECTED_DRIVE${MAGENTA}…${RESET}"
    log "${DIM}  Logging to: $LOG_FILE${RESET}"

    check_mount_status
    check_smart
    check_filesystem
    check_bad_sectors
    check_viruses
    show_summary
}

main "$@"
