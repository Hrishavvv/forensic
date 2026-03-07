#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_DIR="$HOME/forensic_reports"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/forensic_report_$TIMESTAMP.txt"

CLAM_AVAILABLE=false
SMART_AVAILABLE=false
BADBLOCKS_AVAILABLE=false
NTFSFIX_AVAILABLE=false
XFSREPAIR_AVAILABLE=false

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
separator() { log "${DIM}$(printf '─%.0s' {1..60})${RESET}"; }

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_INSTALL="apt-get install -y -qq"
        PKG_UPDATE="apt-get update -qq"
    elif command -v dnf &>/dev/null; then
        PKG_INSTALL="dnf install -y -q"
        PKG_UPDATE="dnf check-update -q"
    elif command -v yum &>/dev/null; then
        PKG_INSTALL="yum install -y -q"
        PKG_UPDATE="yum check-update -q"
    elif command -v pacman &>/dev/null; then
        PKG_INSTALL="pacman -S --noconfirm --quiet"
        PKG_UPDATE="pacman -Sy --quiet"
    else
        PKG_INSTALL=""
        PKG_UPDATE=""
    fi
}

try_install() {
    local pkg="$1"
    local label="$2"
    if [ -z "$PKG_INSTALL" ]; then
        log "${RED}✖  No supported package manager found. Cannot auto-install $label.${RESET}"
        return 1
    fi
    log "${YELLOW}⚙  $label not found. Attempting auto-install…${RESET}"
    if [ "$EUID" -ne 0 ]; then
        sudo $PKG_UPDATE 2>/dev/null
        sudo $PKG_INSTALL "$pkg" 2>/dev/null
    else
        $PKG_UPDATE 2>/dev/null
        $PKG_INSTALL "$pkg" 2>/dev/null
    fi
    if command -v "$label" &>/dev/null || \
       dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || \
       rpm -q "$pkg" 2>/dev/null | grep -q "$pkg"; then
        log "${GREEN}✔  $label installed successfully.${RESET}"
        return 0
    else
        log "${RED}✖  Auto-install of $label failed. Checks requiring it will be skipped.${RESET}"
        return 1
    fi
}

check_deps() {
    detect_pkg_manager

    for cmd in lsblk blkid; do
        if ! command -v "$cmd" &>/dev/null; then
            try_install "util-linux" "$cmd" || {
                log "${RED}✖  $cmd is required and could not be installed. Exiting.${RESET}"
                exit 1
            }
        fi
    done

    if ! command -v fsck &>/dev/null; then
        try_install "e2fsprogs" "fsck" || {
            log "${RED}✖  fsck is required and could not be installed. Exiting.${RESET}"
            exit 1
        }
    fi

    if ! command -v smartctl &>/dev/null; then
        try_install "smartmontools" "smartctl" && SMART_AVAILABLE=true || SMART_AVAILABLE=false
    else
        SMART_AVAILABLE=true
    fi

    if ! command -v clamscan &>/dev/null; then
        try_install "clamav" "clamscan" && {
            log "${CYAN}⚙  Updating ClamAV virus definitions…${RESET}"
            if [ "$EUID" -ne 0 ]; then
                sudo freshclam 2>/dev/null && log "${GREEN}✔  Virus definitions updated.${RESET}" || \
                    log "${YELLOW}⚠  freshclam failed. Definitions may be outdated.${RESET}"
            else
                freshclam 2>/dev/null && log "${GREEN}✔  Virus definitions updated.${RESET}" || \
                    log "${YELLOW}⚠  freshclam failed. Definitions may be outdated.${RESET}"
            fi
            CLAM_AVAILABLE=true
        } || CLAM_AVAILABLE=false
    else
        CLAM_AVAILABLE=true
    fi

    if ! command -v badblocks &>/dev/null; then
        try_install "e2fsprogs" "badblocks" && BADBLOCKS_AVAILABLE=true || BADBLOCKS_AVAILABLE=false
    else
        BADBLOCKS_AVAILABLE=true
    fi

    if ! command -v ntfsfix &>/dev/null; then
        try_install "ntfs-3g" "ntfsfix" && NTFSFIX_AVAILABLE=true || NTFSFIX_AVAILABLE=false
    else
        NTFSFIX_AVAILABLE=true
    fi

    if ! command -v xfs_repair &>/dev/null; then
        try_install "xfsprogs" "xfs_repair" && XFSREPAIR_AVAILABLE=true || XFSREPAIR_AVAILABLE=false
    else
        XFSREPAIR_AVAILABLE=true
    fi

    log ""
    log "${BOLD}${CYAN}▸ Tool availability:${RESET}"
    log "  fsck/e2fsck  : ${GREEN}✔ ready${RESET}"
    log "  smartctl     : $( [ "$SMART_AVAILABLE"     = true ] && echo "${GREEN}✔ ready${RESET}" || echo "${YELLOW}✖ unavailable — SMART checks skipped${RESET}" )"
    log "  clamscan     : $( [ "$CLAM_AVAILABLE"      = true ] && echo "${GREEN}✔ ready${RESET}" || echo "${YELLOW}✖ unavailable — virus scan skipped${RESET}" )"
    log "  badblocks    : $( [ "$BADBLOCKS_AVAILABLE" = true ] && echo "${GREEN}✔ ready${RESET}" || echo "${YELLOW}✖ unavailable — sector scan skipped${RESET}" )"
    log "  ntfsfix      : $( [ "$NTFSFIX_AVAILABLE"   = true ] && echo "${GREEN}✔ ready${RESET}" || echo "${YELLOW}✖ unavailable — NTFS falls back to generic fsck${RESET}" )"
    log "  xfs_repair   : $( [ "$XFSREPAIR_AVAILABLE" = true ] && echo "${GREEN}✔ ready${RESET}" || echo "${YELLOW}✖ unavailable — XFS check skipped${RESET}" )"
    echo ""
}

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

root_warning() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}${BOLD}"
        echo "  ⚠  Not running as root. Some checks require sudo."
        echo "     Re-run with: sudo $0"
        echo -e "${RESET}"
        sleep 2
    fi
}

list_drives() {
    log "${BOLD}${CYAN}▸ Detecting connected block devices…${RESET}"
    echo ""

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
        local dev size type vendor model tran color
        dev=$(echo "$drive" | awk '{print $1}')
        size=$(echo "$drive" | awk '{print $2}')
        type=$(echo "$drive" | awk '{print $3}')
        vendor=$(echo "$drive" | awk '{print $4}')
        model=$(echo "$drive" | awk '{print $5}')
        tran=$(echo "$drive" | awk '{print $6}')
        color=$RESET
        [[ "$tran" == "usb" ]] && color=$YELLOW
        printf "  ${BOLD}%-3s${RESET} ${color}%-12s %-7s %-6s %-11s %s %s${RESET}\n" \
            "$idx)" "$dev" "$size" "$type" "${tran:-N/A}" "$vendor" "$model"
        DRIVE_PATHS+=("$dev")
        ((idx++))
    done
    echo ""
}

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
            echo -e "${RED}  Invalid selection. Enter a number between 1 and $total.${RESET}"
        fi
    done
}

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
    blkid "${SELECTED_DRIVE}"* 2>/dev/null | tee -a "$LOG_FILE" || \
        log "${DIM}  No blkid output (may need root).${RESET}"

    MOUNTED_PARTS=$(lsblk -lno NAME,MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null \
        | awk '$2 != "" {print "/dev/"$1" → "$2}')
    if [ -n "$MOUNTED_PARTS" ]; then
        log ""
        log "${YELLOW}⚠  Mounted partitions detected:${RESET}"
        echo "$MOUNTED_PARTS" | tee -a "$LOG_FILE"
        log "${DIM}  fsck cannot check mounted filesystems.${RESET}"
    else
        log "${GREEN}✔  No partitions currently mounted.${RESET}"
    fi
}

check_smart() {
    log ""
    separator
    log "${BOLD}${BLUE}[2/5] S.M.A.R.T. HEALTH CHECK${RESET}"
    separator

    if [ "$SMART_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  smartctl unavailable — SMART check skipped.${RESET}"
        return
    fi

    log "${CYAN}▸ Running SMART health assessment…${RESET}"
    local smart_out
    smart_out=$(sudo smartctl -H "$SELECTED_DRIVE" 2>&1)
    echo "$smart_out" | tee -a "$LOG_FILE"

    if echo "$smart_out" | grep -q "PASSED"; then
        log "${GREEN}✔  SMART status: PASSED${RESET}"
    elif echo "$smart_out" | grep -q "FAILED"; then
        log "${RED}✖  SMART status: FAILED — drive may be failing!${RESET}"
    else
        log "${YELLOW}⚠  SMART status undetermined (may need root or unsupported device).${RESET}"
    fi

    log ""
    log "${CYAN}▸ Key SMART attributes:${RESET}"
    sudo smartctl -A "$SELECTED_DRIVE" 2>/dev/null \
        | grep -E "Reallocated|Pending|Uncorrectable|Power_On|Temperature|Seek_Error|Spin_Retry" \
        | tee -a "$LOG_FILE" \
        || log "${DIM}  Attributes unavailable.${RESET}"
}

check_filesystem() {
    log ""
    separator
    log "${BOLD}${BLUE}[3/5] FILESYSTEM INTEGRITY CHECK${RESET}"
    separator

    mapfile -t PARTS < <(lsblk -lno NAME,TYPE "$SELECTED_DRIVE" 2>/dev/null \
        | awk '$2=="part"{print "/dev/"$1}')

    if [ ${#PARTS[@]} -eq 0 ]; then
        log "${YELLOW}⚠  No partitions found — checking whole disk device.${RESET}"
        PARTS=("$SELECTED_DRIVE")
    fi

    for part in "${PARTS[@]}"; do
        log "${CYAN}▸ Checking: $part${RESET}"

        if mount | grep -q "^$part "; then
            log "${YELLOW}  ⚠  $part is mounted — skipping (unmount first).${RESET}"
            continue
        fi

        local fstype
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null)
        log "${DIM}  Detected filesystem: ${fstype:-unknown}${RESET}"

        case "$fstype" in
            ext2|ext3|ext4)
                log "${CYAN}  Running e2fsck (read-only, no changes)…${RESET}"
                sudo fsck.ext4 -n "$part" 2>&1 | tee -a "$LOG_FILE"
                ;;
            vfat|fat32|fat16)
                log "${CYAN}  Running fsck.vfat (read-only)…${RESET}"
                sudo fsck.vfat -n "$part" 2>&1 | tee -a "$LOG_FILE"
                ;;
            ntfs)
                if [ "$NTFSFIX_AVAILABLE" = true ]; then
                    log "${CYAN}  Running ntfsfix (check only)…${RESET}"
                    sudo ntfsfix -n "$part" 2>&1 | tee -a "$LOG_FILE"
                else
                    log "${YELLOW}  ⚠  ntfsfix unavailable. Falling back to generic fsck (limited NTFS support)…${RESET}"
                    sudo fsck -n "$part" 2>&1 | tee -a "$LOG_FILE" || \
                        log "${YELLOW}  ⚠  Generic fsck also returned no results for NTFS.${RESET}"
                fi
                ;;
            xfs)
                if [ "$XFSREPAIR_AVAILABLE" = true ]; then
                    log "${CYAN}  Running xfs_repair (dry-run)…${RESET}"
                    sudo xfs_repair -n "$part" 2>&1 | tee -a "$LOG_FILE"
                else
                    log "${YELLOW}  ⚠  xfs_repair unavailable — XFS integrity check skipped.${RESET}"
                fi
                ;;
            btrfs)
                if command -v btrfs &>/dev/null; then
                    log "${CYAN}  Running btrfs check (read-only)…${RESET}"
                    sudo btrfs check --readonly "$part" 2>&1 | tee -a "$LOG_FILE"
                else
                    log "${YELLOW}  ⚠  btrfs tools not found. Attempting install…${RESET}"
                    try_install "btrfs-progs" "btrfs" && \
                        sudo btrfs check --readonly "$part" 2>&1 | tee -a "$LOG_FILE" || \
                        log "${YELLOW}  ⚠  btrfs check skipped.${RESET}"
                fi
                ;;
            "")
                log "${YELLOW}  ⚠  Filesystem undetectable — running generic fsck as fallback…${RESET}"
                sudo fsck -n "$part" 2>&1 | tee -a "$LOG_FILE" || \
                    log "${YELLOW}  ⚠  Generic fsck returned no results.${RESET}"
                ;;
            *)
                log "${YELLOW}  ⚠  Unsupported filesystem '$fstype' — running generic fsck as fallback…${RESET}"
                sudo fsck -n "$part" 2>&1 | tee -a "$LOG_FILE" || \
                    log "${DIM}  Generic fsck returned no useful output for '$fstype'.${RESET}"
                ;;
        esac

        echo "" | tee -a "$LOG_FILE"
    done
}

check_bad_sectors() {
    log ""
    separator
    log "${BOLD}${BLUE}[4/5] BAD SECTOR SCAN (read-only)${RESET}"
    separator

    if [ "$BADBLOCKS_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  badblocks unavailable — bad sector scan skipped.${RESET}"
        return
    fi

    echo -ne "${BOLD}${GREEN}▸ Run bad sector scan? This may take several minutes. [y/N]: ${RESET}"
    read -r do_bad
    if [[ "$do_bad" =~ ^[Yy]$ ]]; then
        log "${CYAN}▸ Scanning $SELECTED_DRIVE for bad sectors…${RESET}"
        local bad_out
        bad_out=$(sudo badblocks -vs "$SELECTED_DRIVE" 2>&1)
        echo "$bad_out" | tee -a "$LOG_FILE"
        local bad_count
        bad_count=$(echo "$bad_out" | grep -c "bad block" || true)
        if [ "$bad_count" -gt 0 ]; then
            log "${RED}✖  Bad sectors found: $bad_count block(s) affected!${RESET}"
        else
            log "${GREEN}✔  No bad sectors detected.${RESET}"
        fi
    else
        log "${DIM}  Bad sector scan skipped.${RESET}"
    fi
}

check_viruses() {
    log ""
    separator
    log "${BOLD}${BLUE}[5/5] MALWARE / VIRUS SCAN (ClamAV)${RESET}"
    separator

    if [ "$CLAM_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  ClamAV unavailable — virus scan skipped.${RESET}"
        return
    fi

    local scan_path
    scan_path=$(lsblk -lno MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null | awk 'NF{print;exit}')

    if [ -z "$scan_path" ]; then
        echo -ne "${BOLD}${GREEN}▸ Drive not mounted. Enter mount point to scan (or Enter to skip): ${RESET}"
        read -r scan_path
        [ -z "$scan_path" ] && { log "${DIM}  Virus scan skipped.${RESET}"; return; }
    fi

    if [ ! -d "$scan_path" ]; then
        log "${YELLOW}⚠  Path '$scan_path' does not exist — skipping.${RESET}"
        return
    fi

    log "${CYAN}▸ Scanning $scan_path with ClamAV…${RESET}"
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
        log "${RED}✖  INFECTED FILES FOUND: $infected — review report for details!${RESET}"
    fi
}

show_summary() {
    log ""
    separator
    log "${BOLD}${MAGENTA}  FORENSIC ANALYSIS COMPLETE${RESET}"
    separator
    log "  Drive analysed : ${YELLOW}$SELECTED_DRIVE${RESET}"
    log "  Timestamp      : $(date '+%Y-%m-%d %H:%M:%S')"
    log "  Full report    : ${CYAN}$LOG_FILE${RESET}"
    separator
    echo ""
}

main() {
    show_banner
    root_warning
    check_deps

    {
        echo "======================================================"
        echo " FORENSIC DRIVE ANALYSIS REPORT"
        echo " Generated : $(date '+%Y-%m-%d %H:%M:%S')"
        echo " Host      : $(hostname) | User: $(whoami)"
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
