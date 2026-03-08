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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORTS_DIR"
REPORT_FILE="$REPORTS_DIR/forensic_report_$TIMESTAMP.txt"

CLAM_AVAILABLE=false
SMART_AVAILABLE=false
BADBLOCKS_AVAILABLE=false
NTFSFIX_AVAILABLE=false
XFSREPAIR_AVAILABLE=false

R_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
R_SMART_STATUS="Not performed"
R_SMART_HEALTH=""
R_SMART_ATTRS=""
R_PARTITIONS=""
R_BLKID=""
R_MOUNT_STATUS=""
R_FS_RESULTS=""
R_BAD_SECTORS="Not performed"
R_VIRUS_STATUS="Not performed"
R_VIRUS_PATH=""
R_INFECTED_COUNT="0"
R_INFECTED_FILES=""
R_TOOLS_MISSING=""
R_VIRUS_SUMMARY=""

MOUNTED_BY_US=()
SPINNER_PID=""

log() { echo -e "$1"; }
separator() { log "${DIM}$(printf '─%.0s' {1..60})${RESET}"; }
rsep() { printf '%.0s─' {1..70}; echo; }

spin_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while true; do
            printf "\r  ${CYAN}${frames[$i]}${RESET}  %s" "$msg"
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

spin_stop() {
    local verdict="${1:-}"
    if [ -n "$SPINNER_PID" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
    fi
    SPINNER_PID=""
    printf "\r\033[2K"
    [ -n "$verdict" ] && echo -e "  $verdict"
}

progress_bar() {
    local current="$1"
    local total="$2"
    local label="$3"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct * 40 / 100 ))
    local empty=$(( 40 - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty; i++)); do bar="${bar}░"; done
    printf "\r  ${CYAN}[%s]${RESET} %3d%%  %s" "$bar" "$pct" "$label"
}

cleanup_mounts() {
    for mnt in "${MOUNTED_BY_US[@]}"; do
        if mount | grep -q " $mnt "; then
            log "${DIM}  Unmounting $mnt (mounted by this tool)…${RESET}"
            if [ "$EUID" -ne 0 ]; then
                sudo umount "$mnt" 2>/dev/null || sudo umount -l "$mnt" 2>/dev/null
            else
                umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null
            fi
        fi
        rmdir "$mnt" 2>/dev/null
    done
}

trap 'spin_stop; cleanup_mounts; echo ""; log "${YELLOW}  Interrupted. Cleaning up…${RESET}"; exit 1' INT TERM

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
        R_TOOLS_MISSING="$R_TOOLS_MISSING $label"
        return 1
    fi
    spin_start "Installing $label…"
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
        spin_stop "${GREEN}✔  $label installed successfully.${RESET}"
        return 0
    else
        spin_stop "${RED}✖  Auto-install of $label failed. Checks requiring it will be skipped.${RESET}"
        R_TOOLS_MISSING="$R_TOOLS_MISSING $label"
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

    local dep_pids=()
    local dep_results_dir
    dep_results_dir=$(mktemp -d)

    _install_bg() {
        local pkg="$1" label="$2" varfile="$3"
        if ! command -v "$label" &>/dev/null; then
            if [ -z "$PKG_INSTALL" ]; then
                echo "false" > "$varfile"
                return
            fi
            if [ "$EUID" -ne 0 ]; then
                sudo $PKG_UPDATE 2>/dev/null
                sudo $PKG_INSTALL "$pkg" 2>/dev/null
            else
                $PKG_UPDATE 2>/dev/null
                $PKG_INSTALL "$pkg" 2>/dev/null
            fi
        fi
        if command -v "$label" &>/dev/null || \
           dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || \
           rpm -q "$pkg" 2>/dev/null | grep -q "$pkg"; then
            echo "true" > "$varfile"
        else
            echo "false" > "$varfile"
        fi
    }

    spin_start "Checking and installing optional tools in parallel…"

    _install_bg "smartmontools" "smartctl"  "$dep_results_dir/smart"  &
    dep_pids+=($!)
    _install_bg "clamav"        "clamscan"  "$dep_results_dir/clam"   &
    dep_pids+=($!)
    _install_bg "e2fsprogs"     "badblocks" "$dep_results_dir/bad"    &
    dep_pids+=($!)
    _install_bg "ntfs-3g"       "ntfsfix"   "$dep_results_dir/ntfs"   &
    dep_pids+=($!)
    _install_bg "xfsprogs"      "xfs_repair" "$dep_results_dir/xfs"  &
    dep_pids+=($!)

    for pid in "${dep_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done
    spin_stop

    [ "$(cat "$dep_results_dir/smart" 2>/dev/null)" = "true" ]  && SMART_AVAILABLE=true     || { SMART_AVAILABLE=false;     R_TOOLS_MISSING="$R_TOOLS_MISSING smartctl"; }
    [ "$(cat "$dep_results_dir/bad"   2>/dev/null)" = "true" ]  && BADBLOCKS_AVAILABLE=true  || { BADBLOCKS_AVAILABLE=false;  R_TOOLS_MISSING="$R_TOOLS_MISSING badblocks"; }
    [ "$(cat "$dep_results_dir/ntfs"  2>/dev/null)" = "true" ]  && NTFSFIX_AVAILABLE=true    || { NTFSFIX_AVAILABLE=false;    R_TOOLS_MISSING="$R_TOOLS_MISSING ntfsfix"; }
    [ "$(cat "$dep_results_dir/xfs"   2>/dev/null)" = "true" ]  && XFSREPAIR_AVAILABLE=true  || { XFSREPAIR_AVAILABLE=false;  R_TOOLS_MISSING="$R_TOOLS_MISSING xfs_repair"; }

    if [ "$(cat "$dep_results_dir/clam" 2>/dev/null)" = "true" ]; then
        CLAM_AVAILABLE=true
        spin_start "Updating ClamAV virus definitions…"
        if [ "$EUID" -ne 0 ]; then
            sudo freshclam 2>/dev/null
        else
            freshclam 2>/dev/null
        fi
        if [ $? -eq 0 ]; then
            spin_stop "${GREEN}✔  ClamAV virus definitions updated.${RESET}"
        else
            spin_stop "${YELLOW}⚠  freshclam failed — definitions may be outdated.${RESET}"
        fi
    else
        CLAM_AVAILABLE=false
        R_TOOLS_MISSING="$R_TOOLS_MISSING clamscan"
    fi

    rm -rf "$dep_results_dir"

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
    echo -e "${DIM}        Reports directory: $REPORTS_DIR${RESET}"
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

do_mount() {
    local dev="$1"
    local fstype="$2"

    local tmp_mnt
    tmp_mnt="/tmp/forensic_mnt_$(basename "$dev")_$$"
    mkdir -p "$tmp_mnt"

    local mount_cmd=""
    case "$fstype" in
        ntfs) mount_cmd="mount -t ntfs-3g -o ro,noatime" ;;
        vfat|fat32|fat16) mount_cmd="mount -t vfat -o ro,noatime" ;;
        exfat) mount_cmd="mount -t exfat -o ro,noatime" ;;
        *) mount_cmd="mount -o ro,noatime" ;;
    esac

    local mount_out
    if [ "$EUID" -ne 0 ]; then
        mount_out=$(sudo $mount_cmd "$dev" "$tmp_mnt" 2>&1)
    else
        mount_out=$($mount_cmd "$dev" "$tmp_mnt" 2>&1)
    fi

    if mount | grep -q " $tmp_mnt "; then
        MOUNTED_BY_US+=("$tmp_mnt")
        echo "$tmp_mnt"
        return 0
    fi

    log "${YELLOW}  ⚠  Primary mount failed ($mount_out). Trying fallback (auto-detect)…${RESET}"
    if [ "$EUID" -ne 0 ]; then
        mount_out=$(sudo mount -o ro "$dev" "$tmp_mnt" 2>&1)
    else
        mount_out=$(mount -o ro "$dev" "$tmp_mnt" 2>&1)
    fi

    if mount | grep -q " $tmp_mnt "; then
        MOUNTED_BY_US+=("$tmp_mnt")
        echo "$tmp_mnt"
        return 0
    fi

    log "${RED}  ✖  All mount attempts failed for $dev: $mount_out${RESET}"
    rmdir "$tmp_mnt" 2>/dev/null
    echo ""
    return 1
}

do_unmount() {
    local mnt="$1"
    local lazy=false

    if [ "$EUID" -ne 0 ]; then
        sudo umount "$mnt" 2>/dev/null || { lazy=true; sudo umount -l "$mnt" 2>/dev/null; }
    else
        umount "$mnt" 2>/dev/null || { lazy=true; umount -l "$mnt" 2>/dev/null; }
    fi

    if mount | grep -q " $mnt "; then
        log "${RED}  ✖  Could not unmount $mnt.${RESET}"
        return 1
    fi

    [ "$lazy" = true ] && log "${YELLOW}  ⚠  Lazy unmount used for $mnt (was busy).${RESET}" \
                       || log "${GREEN}  ✔  $mnt unmounted cleanly.${RESET}"
    rmdir "$mnt" 2>/dev/null
    MOUNTED_BY_US=("${MOUNTED_BY_US[@]/$mnt}")
    return 0
}

check_mount_status() {
    log ""
    separator
    log "${BOLD}${BLUE}[1/5] MOUNT STATUS & PARTITION TABLE${RESET}"
    separator

    spin_start "Reading partition table…"
    R_PARTITIONS=$(lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID "$SELECTED_DRIVE" 2>/dev/null)
    R_BLKID=$(blkid "${SELECTED_DRIVE}"* 2>/dev/null)
    spin_stop

    log "${CYAN}▸ Partitions on $SELECTED_DRIVE:${RESET}"
    echo "$R_PARTITIONS"
    echo ""

    log "${CYAN}▸ Filesystem identifiers (blkid):${RESET}"
    if [ -n "$R_BLKID" ]; then
        echo "$R_BLKID"
    else
        log "${DIM}  No blkid output (may need root).${RESET}"
        R_BLKID="Not available (run as root for full output)"
    fi

    MOUNTED_PARTS=$(lsblk -lno NAME,MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null \
        | awk '$2 != "" {print "/dev/"$1" -> "$2}')
    if [ -n "$MOUNTED_PARTS" ]; then
        log ""
        log "${YELLOW}⚠  Mounted partitions detected:${RESET}"
        echo "$MOUNTED_PARTS"
        R_MOUNT_STATUS="Some partitions were mounted at scan time"$'\n'"$MOUNTED_PARTS"
    else
        log "${GREEN}✔  No partitions currently mounted.${RESET}"
        R_MOUNT_STATUS="All partitions confirmed unmounted at time of scan"
    fi
}

check_smart() {
    log ""
    separator
    log "${BOLD}${BLUE}[2/5] S.M.A.R.T. HEALTH CHECK${RESET}"
    separator

    if [ "$SMART_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  smartctl unavailable — SMART check skipped.${RESET}"
        R_SMART_STATUS="SKIPPED — smartctl not available"
        return
    fi

    spin_start "Running SMART health assessment…"
    local smart_out
    if [ "$EUID" -ne 0 ]; then
        smart_out=$(sudo smartctl -H "$SELECTED_DRIVE" 2>&1)
    else
        smart_out=$(smartctl -H "$SELECTED_DRIVE" 2>&1)
    fi
    R_SMART_HEALTH="$smart_out"

    if echo "$smart_out" | grep -q "PASSED"; then
        spin_stop "${GREEN}✔  SMART status: PASSED${RESET}"
        R_SMART_STATUS="PASSED — drive health self-test returned no failures"
    elif echo "$smart_out" | grep -q "FAILED"; then
        spin_stop "${RED}✖  SMART status: FAILED — drive may be failing!${RESET}"
        R_SMART_STATUS="FAILED — drive health self-test indicates hardware failure risk"
    else
        spin_stop "${YELLOW}⚠  SMART status undetermined (may need root or unsupported device).${RESET}"
        R_SMART_STATUS="UNDETERMINED — smartctl ran but could not confirm pass/fail status"
    fi

    spin_start "Reading SMART attributes…"
    if [ "$EUID" -ne 0 ]; then
        R_SMART_ATTRS=$(sudo smartctl -A "$SELECTED_DRIVE" 2>/dev/null \
            | grep -E "Reallocated|Pending|Uncorrectable|Power_On|Temperature|Seek_Error|Spin_Retry")
    else
        R_SMART_ATTRS=$(smartctl -A "$SELECTED_DRIVE" 2>/dev/null \
            | grep -E "Reallocated|Pending|Uncorrectable|Power_On|Temperature|Seek_Error|Spin_Retry")
    fi
    spin_stop

    log "${CYAN}▸ Key SMART attributes:${RESET}"
    if [ -n "$R_SMART_ATTRS" ]; then
        echo "$R_SMART_ATTRS"
    else
        log "${DIM}  Attributes unavailable.${RESET}"
        R_SMART_ATTRS="Not available"
    fi
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

    R_FS_RESULTS=""
    local total_parts=${#PARTS[@]}
    local part_idx=0

    for part in "${PARTS[@]}"; do
        ((part_idx++))
        log "${CYAN}▸ Checking partition $part_idx/$total_parts: $part${RESET}"

        local was_mounted=false
        local our_mount=""
        local existing_mount=""

        existing_mount=$(lsblk -lno MOUNTPOINT "$part" 2>/dev/null | awk 'NF{print;exit}')

        if [ -n "$existing_mount" ]; then
            was_mounted=true
            log "${YELLOW}  ⚠  $part is mounted at $existing_mount — unmounting for fsck…${RESET}"
            if [ "$EUID" -ne 0 ]; then
                sudo umount "$part" 2>/dev/null || sudo umount -l "$part" 2>/dev/null
            else
                umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null
            fi
            if mount | grep -q "^$part "; then
                log "${RED}  ✖  Cannot unmount $part — skipping fsck.${RESET}"
                R_FS_RESULTS="$R_FS_RESULTS"$'\n'"Partition : $part"$'\n'"Verdict   : SKIPPED — could not unmount for checking"$'\n'
                continue
            else
                log "${GREEN}  ✔  Unmounted $part successfully.${RESET}"
            fi
        fi

        local fstype
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null)
        log "${DIM}  Detected filesystem: ${fstype:-unknown}${RESET}"

        local fsck_out=""
        local fsck_verdict=""

        spin_start "Running integrity check on $part ($fstype)…"

        case "$fstype" in
            ext2|ext3|ext4)
                if [ "$EUID" -ne 0 ]; then
                    fsck_out=$(sudo fsck.ext4 -n "$part" 2>&1)
                else
                    fsck_out=$(fsck.ext4 -n "$part" 2>&1)
                fi
                if echo "$fsck_out" | grep -qiE "clean|no problems"; then
                    fsck_verdict="CLEAN — no filesystem errors detected"
                elif echo "$fsck_out" | grep -qiE "error|corrupt|bad|problem"; then
                    fsck_verdict="ERRORS FOUND — filesystem corruption detected"
                else
                    fsck_verdict="CHECK COMPLETE — review raw output for details"
                fi
                ;;
            vfat|fat32|fat16)
                if [ "$EUID" -ne 0 ]; then
                    fsck_out=$(sudo fsck.vfat -n "$part" 2>&1)
                else
                    fsck_out=$(fsck.vfat -n "$part" 2>&1)
                fi
                if echo "$fsck_out" | grep -qi "no errors"; then
                    fsck_verdict="CLEAN — no FAT filesystem errors detected"
                elif echo "$fsck_out" | grep -qiE "error|corrupt|bad"; then
                    fsck_verdict="ERRORS FOUND — FAT filesystem issues detected"
                else
                    fsck_verdict="CHECK COMPLETE — review raw output for details"
                fi
                ;;
            ntfs)
                if [ "$NTFSFIX_AVAILABLE" = true ]; then
                    if [ "$EUID" -ne 0 ]; then
                        fsck_out=$(sudo ntfsfix -n "$part" 2>&1)
                    else
                        fsck_out=$(ntfsfix -n "$part" 2>&1)
                    fi
                    if echo "$fsck_out" | grep -qi "no errors\|consistent"; then
                        fsck_verdict="CLEAN — NTFS filesystem consistent"
                    elif echo "$fsck_out" | grep -qiE "error|corrupt|inconsisten"; then
                        fsck_verdict="ERRORS FOUND — NTFS inconsistency detected"
                    else
                        fsck_verdict="CHECK COMPLETE — review raw output for details"
                    fi
                else
                    spin_stop "${YELLOW}  ⚠  ntfsfix unavailable. Falling back to generic fsck…${RESET}"
                    spin_start "Running generic fsck on $part…"
                    if [ "$EUID" -ne 0 ]; then
                        fsck_out=$(sudo fsck -n "$part" 2>&1)
                    else
                        fsck_out=$(fsck -n "$part" 2>&1)
                    fi
                    fsck_verdict="CHECK PERFORMED (generic fsck fallback — limited NTFS accuracy)"
                fi
                ;;
            xfs)
                if [ "$XFSREPAIR_AVAILABLE" = true ]; then
                    if [ "$EUID" -ne 0 ]; then
                        fsck_out=$(sudo xfs_repair -n "$part" 2>&1)
                    else
                        fsck_out=$(xfs_repair -n "$part" 2>&1)
                    fi
                    if echo "$fsck_out" | grep -qi "no modify"; then
                        fsck_verdict="CLEAN — XFS filesystem no repairs needed"
                    elif echo "$fsck_out" | grep -qiE "would fix|error|corrupt"; then
                        fsck_verdict="ERRORS FOUND — XFS repair needed"
                    else
                        fsck_verdict="CHECK COMPLETE — review raw output for details"
                    fi
                else
                    fsck_out="xfs_repair not available"
                    fsck_verdict="SKIPPED — xfs_repair not installed"
                fi
                ;;
            btrfs)
                if command -v btrfs &>/dev/null; then
                    if [ "$EUID" -ne 0 ]; then
                        fsck_out=$(sudo btrfs check --readonly "$part" 2>&1)
                    else
                        fsck_out=$(btrfs check --readonly "$part" 2>&1)
                    fi
                    if echo "$fsck_out" | grep -qi "no error"; then
                        fsck_verdict="CLEAN — btrfs filesystem no errors found"
                    elif echo "$fsck_out" | grep -qiE "error|corrupt"; then
                        fsck_verdict="ERRORS FOUND — btrfs issues detected"
                    else
                        fsck_verdict="CHECK COMPLETE — review raw output for details"
                    fi
                else
                    fsck_out="btrfs-progs not available"
                    fsck_verdict="SKIPPED — btrfs tools not installed"
                fi
                ;;
            "")
                if [ "$EUID" -ne 0 ]; then
                    fsck_out=$(sudo fsck -n "$part" 2>&1)
                else
                    fsck_out=$(fsck -n "$part" 2>&1)
                fi
                fsck_verdict="CHECK PERFORMED (generic fsck — filesystem type unknown)"
                ;;
            *)
                if [ "$EUID" -ne 0 ]; then
                    fsck_out=$(sudo fsck -n "$part" 2>&1)
                else
                    fsck_out=$(fsck -n "$part" 2>&1)
                fi
                fsck_verdict="CHECK PERFORMED (generic fsck fallback for '$fstype')"
                ;;
        esac

        if echo "$fsck_verdict" | grep -qi "CLEAN"; then
            spin_stop "${GREEN}  ✔  $part — $fsck_verdict${RESET}"
        elif echo "$fsck_verdict" | grep -qi "ERRORS"; then
            spin_stop "${RED}  ✖  $part — $fsck_verdict${RESET}"
        else
            spin_stop "${YELLOW}  ⚠  $part — $fsck_verdict${RESET}"
        fi

        if [ "$was_mounted" = true ] && [ -n "$existing_mount" ]; then
            log "${CYAN}  ↩  Re-mounting $part at $existing_mount…${RESET}"
            if [ "$EUID" -ne 0 ]; then
                sudo mount "$part" "$existing_mount" 2>/dev/null && \
                    log "${GREEN}  ✔  Re-mounted successfully.${RESET}" || \
                    log "${YELLOW}  ⚠  Re-mount failed — $part remains unmounted.${RESET}"
            else
                mount "$part" "$existing_mount" 2>/dev/null && \
                    log "${GREEN}  ✔  Re-mounted successfully.${RESET}" || \
                    log "${YELLOW}  ⚠  Re-mount failed — $part remains unmounted.${RESET}"
            fi
        fi

        R_FS_RESULTS="$R_FS_RESULTS"$'\n'"Partition : $part"$'\n'"Filesystem: ${fstype:-unknown}"$'\n'"Verdict   : $fsck_verdict"$'\n'"Raw Output:"$'\n'"$fsck_out"$'\n'

        progress_bar "$part_idx" "$total_parts" "Filesystem checks"
        echo ""
    done
    echo ""
}

check_bad_sectors() {
    log ""
    separator
    log "${BOLD}${BLUE}[4/5] BAD SECTOR SCAN (read-only)${RESET}"
    separator

    if [ "$BADBLOCKS_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  badblocks unavailable — bad sector scan skipped.${RESET}"
        R_BAD_SECTORS="SKIPPED — badblocks not available"
        return
    fi

    echo -ne "${BOLD}${GREEN}▸ Run bad sector scan? This may take several minutes. [y/N]: ${RESET}"
    read -r do_bad
    if [[ "$do_bad" =~ ^[Yy]$ ]]; then
        log "${CYAN}▸ Scanning $SELECTED_DRIVE for bad sectors…${RESET}"

        local tmpfile
        tmpfile=$(mktemp)

        if [ "$EUID" -ne 0 ]; then
            sudo badblocks -vs "$SELECTED_DRIVE" > "$tmpfile" 2>&1 &
        else
            badblocks -vs "$SELECTED_DRIVE" > "$tmpfile" 2>&1 &
        fi
        local bb_pid=$!

        local dot_count=0
        while kill -0 "$bb_pid" 2>/dev/null; do
            local elapsed_blocks
            elapsed_blocks=$(grep -c "." "$tmpfile" 2>/dev/null || echo 0)
            printf "\r  ${CYAN}⠿${RESET}  Scanning blocks… (%s lines processed)" "$elapsed_blocks"
            sleep 1
        done
        wait "$bb_pid"
        printf "\r\033[2K"

        local bad_out
        bad_out=$(cat "$tmpfile")
        rm -f "$tmpfile"

        echo "$bad_out"

        local bad_count
        bad_count=$(echo "$bad_out" | grep -c "bad block" 2>/dev/null || echo 0)
        if [ "$bad_count" -gt 0 ]; then
            log "${RED}✖  Bad sectors found: $bad_count block(s) affected!${RESET}"
            R_BAD_SECTORS="FAILED — $bad_count bad block(s) detected on $SELECTED_DRIVE"$'\n'"$bad_out"
        else
            log "${GREEN}✔  No bad sectors detected.${RESET}"
            R_BAD_SECTORS="PASSED — no bad sectors found across entire drive surface"
        fi
    else
        log "${DIM}  Bad sector scan skipped.${RESET}"
        R_BAD_SECTORS="SKIPPED — user opted out"
    fi
}

check_viruses() {
    log ""
    separator
    log "${BOLD}${BLUE}[5/5] MALWARE / VIRUS SCAN (ClamAV)${RESET}"
    separator

    if [ "$CLAM_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  ClamAV unavailable — virus scan skipped.${RESET}"
        R_VIRUS_STATUS="SKIPPED — ClamAV not available"
        return
    fi

    local scan_path
    scan_path=$(lsblk -lno MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null | awk 'NF{print;exit}')

    if [ -z "$scan_path" ]; then
        log "${YELLOW}▸ Drive not mounted. Attempting to mount for virus scan…${RESET}"
        local fstype
        fstype=$(blkid -o value -s TYPE "${SELECTED_DRIVE}1" 2>/dev/null)
        [ -z "$fstype" ] && fstype=$(blkid -o value -s TYPE "$SELECTED_DRIVE" 2>/dev/null)

        spin_start "Mounting $SELECTED_DRIVE…"
        scan_path=$(do_mount "${SELECTED_DRIVE}1" "$fstype" 2>/dev/null)
        [ -z "$scan_path" ] && scan_path=$(do_mount "$SELECTED_DRIVE" "$fstype" 2>/dev/null)
        spin_stop

        if [ -z "$scan_path" ]; then
            log "${YELLOW}  ⚠  Auto-mount failed.${RESET}"
            echo -ne "${BOLD}${GREEN}▸ Enter mount point manually (or Enter to skip): ${RESET}"
            read -r scan_path
            if [ -z "$scan_path" ]; then
                log "${DIM}  Virus scan skipped.${RESET}"
                R_VIRUS_STATUS="SKIPPED — drive not mounted and auto-mount failed"
                return
            fi
        else
            log "${GREEN}  ✔  Drive mounted at $scan_path for scanning.${RESET}"
        fi
    fi

    if [ ! -d "$scan_path" ]; then
        log "${YELLOW}⚠  Path '$scan_path' does not exist — skipping.${RESET}"
        R_VIRUS_STATUS="SKIPPED — provided path '$scan_path' does not exist"
        return
    fi

    R_VIRUS_PATH="$scan_path"
    log "${CYAN}▸ Scanning $scan_path with ClamAV…${RESET}"

    local tmpfile
    tmpfile=$(mktemp)
    local scanned=0

    clamscan -r --bell -i "$scan_path" > "$tmpfile" 2>&1 &
    local clam_pid=$!

    while kill -0 "$clam_pid" 2>/dev/null; do
        scanned=$(grep -c "^/" "$tmpfile" 2>/dev/null || echo 0)
        printf "\r  ${CYAN}⠿${RESET}  Scanning… (%s files scanned)" "$scanned"
        sleep 0.5
    done
    wait "$clam_pid"
    printf "\r\033[2K"

    local clam_out
    clam_out=$(cat "$tmpfile")
    rm -f "$tmpfile"

    echo "$clam_out"

    R_INFECTED_COUNT=$(echo "$clam_out" | grep "^Infected files:" | awk '{print $3}')
    R_INFECTED_COUNT="${R_INFECTED_COUNT:-0}"

    local scanned_files known_viruses
    scanned_files=$(echo "$clam_out" | grep "^Scanned files:" | awk '{print $3}')
    known_viruses=$(echo "$clam_out" | grep "Known viruses:" | awk '{print $3}')

    echo ""
    if [ "$R_INFECTED_COUNT" = "0" ]; then
        log "${GREEN}✔  No malware detected. Drive appears clean.${RESET}"
        R_VIRUS_STATUS="CLEAN — no malware or infected files detected"
    else
        log "${RED}✖  INFECTED FILES FOUND: $R_INFECTED_COUNT — review report for details!${RESET}"
        R_VIRUS_STATUS="INFECTED — $R_INFECTED_COUNT infected file(s) found"
        R_INFECTED_FILES=$(echo "$clam_out" | grep "FOUND")
    fi

    R_VIRUS_SUMMARY="Scanned files  : ${scanned_files:-N/A}"$'\n'"Known viruses  : ${known_viruses:-N/A}"$'\n'"Infected files : $R_INFECTED_COUNT"
}

write_report() {
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')

    local drive_model drive_size drive_tran drive_serial
    drive_model=$(lsblk -dno MODEL "$SELECTED_DRIVE" 2>/dev/null | xargs)
    drive_size=$(lsblk -dno SIZE "$SELECTED_DRIVE" 2>/dev/null | xargs)
    drive_tran=$(lsblk -dno TRAN "$SELECTED_DRIVE" 2>/dev/null | xargs)
    if [ "$EUID" -ne 0 ]; then
        drive_serial=$(sudo smartctl -i "$SELECTED_DRIVE" 2>/dev/null | grep "Serial Number" | awk -F: '{print $2}' | xargs)
    else
        drive_serial=$(smartctl -i "$SELECTED_DRIVE" 2>/dev/null | grep "Serial Number" | awk -F: '{print $2}' | xargs)
    fi

    {
        echo "========================================================================"
        echo "                  FORENSIC DRIVE ANALYSIS REPORT"
        echo "========================================================================"
        echo ""
        echo "  Report File   : $REPORT_FILE"
        echo "  Analyst Host  : $(hostname)"
        echo "  Analyst User  : $(whoami)"
        echo "  Analysis Start: $R_START_TIME"
        echo "  Analysis End  : $end_time"
        echo "  Tool Version  : Forensic Drive Analyser v2.0"
        echo ""
        rsep
        echo "  SECTION 1 — TARGET DRIVE IDENTIFICATION"
        rsep
        echo ""
        echo "  Device Path   : $SELECTED_DRIVE"
        echo "  Model         : ${drive_model:-Not available}"
        echo "  Capacity      : ${drive_size:-Not available}"
        echo "  Interface     : ${drive_tran:-Not available}"
        echo "  Serial Number : ${drive_serial:-Not available (run as root)}"
        echo ""
        echo "  Partition Layout:"
        echo "$R_PARTITIONS" | sed 's/^/    /'
        echo ""
        echo "  Block Device Identifiers (blkid):"
        echo "$R_BLKID" | sed 's/^/    /'
        echo ""
        echo "  Mount Status at Time of Scan:"
        echo "    $R_MOUNT_STATUS"
        echo ""
        rsep
        echo "  SECTION 2 — S.M.A.R.T. HEALTH ASSESSMENT"
        rsep
        echo ""
        echo "  Overall Verdict: $R_SMART_STATUS"
        echo ""
        if [ -n "$R_SMART_ATTRS" ] && [ "$R_SMART_ATTRS" != "Not available" ]; then
            echo "  Key SMART Attributes:"
            echo "$R_SMART_ATTRS" | sed 's/^/    /'
            echo ""
            echo "  Attribute Interpretation:"
            echo "    Reallocated_Sector_Ct  — Count of remapped bad sectors. Non-zero = physical damage."
            echo "    Current_Pending_Sector — Sectors waiting to be remapped. Non-zero = instability risk."
            echo "    Offline_Uncorrectable  — Sectors that failed correction. Any value = serious concern."
            echo "    Seek_Error_Rate        — Mechanical read/write head positioning failures."
            echo "    Spin_Retry_Count       — Failed spindle start attempts. Non-zero = motor stress."
        elif [ "$R_SMART_STATUS" != "SKIPPED — smartctl not available" ]; then
            echo "  Full SMART Health Output:"
            echo "$R_SMART_HEALTH" | sed 's/^/    /'
        else
            echo "  smartctl was not available on this system. Install smartmontools for drive"
            echo "  health monitoring on future scans."
        fi
        echo ""
        rsep
        echo "  SECTION 3 — FILESYSTEM INTEGRITY ANALYSIS"
        rsep
        echo ""
        if [ -n "$R_FS_RESULTS" ]; then
            echo "$R_FS_RESULTS" | sed 's/^/  /'
        else
            echo "  No filesystem check results recorded."
        fi
        echo ""
        rsep
        echo "  SECTION 4 — BAD SECTOR SURFACE SCAN"
        rsep
        echo ""
        echo "  Verdict: $R_BAD_SECTORS"
        echo ""
        echo "  Note: Bad sectors indicate physical media degradation. Even one bad sector"
        echo "  on a drive that is actively used warrants immediate backup and drive replacement."
        echo ""
        rsep
        echo "  SECTION 5 — MALWARE & VIRUS SCAN"
        rsep
        echo ""
        echo "  Scanner       : ClamAV (clamscan)"
        echo "  Scanned Path  : ${R_VIRUS_PATH:-N/A}"
        echo "  Verdict       : $R_VIRUS_STATUS"
        echo ""
        if [ -n "$R_VIRUS_SUMMARY" ]; then
            echo "  Scan Statistics:"
            echo "$R_VIRUS_SUMMARY" | sed 's/^/    /'
            echo ""
        fi
        if [ -n "$R_INFECTED_FILES" ]; then
            echo "  Infected Files Detected:"
            echo "$R_INFECTED_FILES" | sed 's/^/    /'
            echo ""
            echo "  Recommendation: Quarantine or delete infected files immediately."
            echo "  Do not execute or open any of the listed files."
        fi
        echo ""
        rsep
        echo "  SECTION 6 — ANALYSIS SUMMARY & RECOMMENDATIONS"
        rsep
        echo ""
        echo "  Drive            : $SELECTED_DRIVE (${drive_model:-unknown model})"
        echo "  SMART Health     : $R_SMART_STATUS"
        echo "  Filesystem Check : $([ -n "$R_FS_RESULTS" ] && echo "Performed — see Section 3 for per-partition results" || echo "Not performed")"
        echo "  Bad Sectors      : $R_BAD_SECTORS"
        echo "  Malware          : $R_VIRUS_STATUS"
        echo ""
        echo "  Overall Risk Assessment:"

        local risk_level="LOW"
        local risk_notes=""

        if echo "$R_SMART_STATUS" | grep -qi "FAILED"; then
            risk_level="CRITICAL"
            risk_notes="$risk_notes"$'\n'"  - SMART failure detected: drive hardware is at risk of imminent failure."
        fi
        if echo "$R_BAD_SECTORS" | grep -qi "FAILED\|bad block"; then
            risk_level="HIGH"
            risk_notes="$risk_notes"$'\n'"  - Bad sectors found: physical media damage confirmed."
        fi
        if echo "$R_FS_RESULTS" | grep -qi "ERRORS FOUND"; then
            [ "$risk_level" = "LOW" ] && risk_level="MEDIUM"
            risk_notes="$risk_notes"$'\n'"  - Filesystem corruption detected on one or more partitions."
        fi
        if echo "$R_VIRUS_STATUS" | grep -qi "INFECTED"; then
            [ "$risk_level" = "LOW" ] && risk_level="HIGH"
            risk_notes="$risk_notes"$'\n'"  - Malware found: $R_INFECTED_COUNT infected file(s) require immediate action."
        fi

        echo "  Risk Level: $risk_level"
        if [ -n "$risk_notes" ]; then
            echo ""
            echo "  Issues Found:"
            echo "$risk_notes"
        else
            echo ""
            echo "  No critical issues identified during this analysis."
        fi

        echo ""
        if [ -n "$R_TOOLS_MISSING" ]; then
            echo "  Tools Not Available During Scan:$R_TOOLS_MISSING"
            echo "  Re-running with all tools installed may produce a more complete assessment."
            echo ""
        fi
        rsep
        echo "  END OF REPORT"
        rsep
        echo ""
        echo "  This report was generated automatically by Forensic Drive Analyser."
        echo "  All filesystem checks were performed in READ-ONLY mode. No data was"
        echo "  modified on the target drive during this analysis."
        echo ""
        echo "  Report saved to: $REPORT_FILE"
        echo ""
    } > "$REPORT_FILE"
}

show_summary() {
    cleanup_mounts
    write_report
    log ""
    separator
    log "${BOLD}${MAGENTA}  FORENSIC ANALYSIS COMPLETE${RESET}"
    separator
    log "  Drive analysed : ${YELLOW}$SELECTED_DRIVE${RESET}"
    log "  Finished       : $(date '+%Y-%m-%d %H:%M:%S')"
    log "  Reports folder : ${CYAN}$REPORTS_DIR${RESET}"
    log "  Report saved   : ${CYAN}$REPORT_FILE${RESET}"
    separator
    echo ""
}

main() {
    show_banner
    root_warning
    check_deps

    list_drives
    select_drive

    log ""
    log "${BOLD}${MAGENTA}▸ Starting forensic analysis of ${YELLOW}$SELECTED_DRIVE${MAGENTA}…${RESET}"

    check_mount_status
    check_smart
    check_filesystem
    check_bad_sectors
    check_viruses
    show_summary
}

main "$@"
