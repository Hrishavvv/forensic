#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORTS_DIR"
REPORT_FILE="$REPORTS_DIR/forensic_report_$TIMESTAMP.txt"

CLAM_AVAILABLE=false; SMART_AVAILABLE=false; BADBLOCKS_AVAILABLE=false
NTFSFIX_AVAILABLE=false; XFSREPAIR_AVAILABLE=false
SPINNER_PID=""; MOUNTED_BY_US=()

R_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
R_SMART_STATUS="Not performed"; R_SMART_HEALTH=""; R_SMART_ATTRS=""
R_PARTITIONS=""; R_BLKID=""; R_MOUNT_STATUS=""; R_FS_RESULTS=""
R_BAD_SECTORS="Not performed"; R_VIRUS_STATUS="Not performed"
R_VIRUS_PATH=""; R_INFECTED_COUNT="0"; R_INFECTED_FILES=""
R_TOOLS_MISSING=""; R_VIRUS_SUMMARY=""

log()  { echo -e "$1"; }
sep()  { printf "${DIM}"; printf '─%.0s' {1..60}; printf "${RESET}\n"; }
rsep() { printf '─%.0s' {1..70}; echo; }

spin_start() {
    [ -n "$SPINNER_PID" ] && spin_stop
    local msg="$1"
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r  \e[36m%s\e[0m  %s   " "${frames[$i]}" "$msg"
            i=$(( (i+1) % 10 ))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

spin_stop() {
    local msg="${1:-}"
    if [ -n "$SPINNER_PID" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
    fi
    SPINNER_PID=""
    printf "\r\033[2K"
    [ -n "$msg" ] && echo -e "  $msg"
}

run_with_spinner() {
    local msg="$1"; shift
    spin_start "$msg"
    local out
    out=$("$@" 2>&1)
    local rc=$?
    spin_stop
    echo "$out"
    return $rc
}

cleanup_mounts() {
    for mnt in "${MOUNTED_BY_US[@]}"; do
        [ -z "$mnt" ] && continue
        if mount | grep -q " $mnt "; then
            if [ "$EUID" -ne 0 ]; then
                sudo umount "$mnt" 2>/dev/null || sudo umount -l "$mnt" 2>/dev/null
            else
                umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null
            fi
        fi
        rmdir "$mnt" 2>/dev/null
    done
}

trap 'spin_stop; cleanup_mounts; printf "\n"; log "${YELLOW}  Interrupted — cleaned up.${RESET}"; exit 1' INT TERM

detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then PKG_MGR="apt"; PKG_INSTALL="apt-get install -y -qq"; PKG_UPDATE="apt-get update -qq"
    elif command -v dnf     &>/dev/null; then PKG_MGR="dnf"; PKG_INSTALL="dnf install -y -q";      PKG_UPDATE="dnf check-update -q"
    elif command -v yum     &>/dev/null; then PKG_MGR="yum"; PKG_INSTALL="yum install -y -q";      PKG_UPDATE="yum check-update -q"
    elif command -v pacman  &>/dev/null; then PKG_MGR="pac"; PKG_INSTALL="pacman -S --noconfirm";  PKG_UPDATE="pacman -Sy"
    else PKG_MGR=""; PKG_INSTALL=""; PKG_UPDATE=""; fi
}

pkg_install() {
    local pkg="$1" label="$2"
    [ -z "$PKG_INSTALL" ] && { R_TOOLS_MISSING+=" $label"; return 1; }
    if [ "$EUID" -ne 0 ]; then
        sudo $PKG_UPDATE >/dev/null 2>&1
        sudo $PKG_INSTALL "$pkg" >/dev/null 2>&1
    else
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL "$pkg" >/dev/null 2>&1
    fi
    command -v "$label" &>/dev/null && return 0
    R_TOOLS_MISSING+=" $label"; return 1
}

check_deps() {
    detect_pkg_manager

    for cmd in lsblk blkid fsck; do
        if ! command -v "$cmd" &>/dev/null; then
            spin_start "Installing $cmd…"
            pkg_install "util-linux e2fsprogs" "$cmd"
            command -v "$cmd" &>/dev/null && spin_stop "${GREEN}✔ $cmd ready${RESET}" || { spin_stop "${RED}✖ $cmd required, install failed — exiting${RESET}"; exit 1; }
        fi
    done

    local tmp_dir
    tmp_dir=$(mktemp -d)

    _bg_check() {
        local pkg="$1" cmd="$2" out="$3"
        if ! command -v "$cmd" &>/dev/null; then
            [ -z "$PKG_INSTALL" ] && { echo "false" > "$out"; return; }
            if [ "$EUID" -ne 0 ]; then
                sudo $PKG_UPDATE >/dev/null 2>&1; sudo $PKG_INSTALL "$pkg" >/dev/null 2>&1
            else
                $PKG_UPDATE >/dev/null 2>&1; $PKG_INSTALL "$pkg" >/dev/null 2>&1
            fi
        fi
        command -v "$cmd" &>/dev/null && echo "true" > "$out" || echo "false" > "$out"
    }

    spin_start "Checking tools (parallel)…"
    _bg_check "smartmontools" "smartctl"  "$tmp_dir/smart"  &
    _bg_check "clamav"        "clamscan"  "$tmp_dir/clam"   &
    _bg_check "e2fsprogs"     "badblocks" "$tmp_dir/bad"    &
    _bg_check "ntfs-3g"       "ntfsfix"   "$tmp_dir/ntfs"   &
    _bg_check "xfsprogs"      "xfs_repair" "$tmp_dir/xfs"  &
    wait
    spin_stop

    [ "$(cat "$tmp_dir/smart" 2>/dev/null)" = "true" ]   && SMART_AVAILABLE=true     || { SMART_AVAILABLE=false;    R_TOOLS_MISSING+=" smartctl";  }
    [ "$(cat "$tmp_dir/bad"   2>/dev/null)" = "true" ]   && BADBLOCKS_AVAILABLE=true  || { BADBLOCKS_AVAILABLE=false; R_TOOLS_MISSING+=" badblocks"; }
    [ "$(cat "$tmp_dir/ntfs"  2>/dev/null)" = "true" ]   && NTFSFIX_AVAILABLE=true    || { NTFSFIX_AVAILABLE=false;   R_TOOLS_MISSING+=" ntfsfix";   }
    [ "$(cat "$tmp_dir/xfs"   2>/dev/null)" = "true" ]   && XFSREPAIR_AVAILABLE=true  || { XFSREPAIR_AVAILABLE=false; R_TOOLS_MISSING+=" xfs_repair";}

    if [ "$(cat "$tmp_dir/clam" 2>/dev/null)" = "true" ]; then
        CLAM_AVAILABLE=true
        spin_start "Updating ClamAV definitions…"
        if [ "$EUID" -ne 0 ]; then sudo freshclam >/dev/null 2>&1; else freshclam >/dev/null 2>&1; fi
        [ $? -eq 0 ] && spin_stop "${GREEN}✔ ClamAV definitions updated${RESET}" || spin_stop "${YELLOW}⚠ ClamAV definitions update failed${RESET}"
    else
        CLAM_AVAILABLE=false; R_TOOLS_MISSING+=" clamscan"
    fi
    rm -rf "$tmp_dir"

    echo ""
    log "${BOLD}${CYAN}▸ Tool status:${RESET}"
    printf "  %-14s %s\n" "fsck/e2fsck:"  "$(echo -e "${GREEN}✔ ready${RESET}")"
    printf "  %-14s %s\n" "smartctl:"     "$( [ "$SMART_AVAILABLE"     = true ] && echo -e "${GREEN}✔ ready${RESET}" || echo -e "${YELLOW}✖ unavailable${RESET}" )"
    printf "  %-14s %s\n" "clamscan:"     "$( [ "$CLAM_AVAILABLE"      = true ] && echo -e "${GREEN}✔ ready${RESET}" || echo -e "${YELLOW}✖ unavailable${RESET}" )"
    printf "  %-14s %s\n" "badblocks:"    "$( [ "$BADBLOCKS_AVAILABLE" = true ] && echo -e "${GREEN}✔ ready${RESET}" || echo -e "${YELLOW}✖ unavailable${RESET}" )"
    printf "  %-14s %s\n" "ntfsfix:"      "$( [ "$NTFSFIX_AVAILABLE"   = true ] && echo -e "${GREEN}✔ ready${RESET}" || echo -e "${YELLOW}✖ unavailable${RESET}" )"
    printf "  %-14s %s\n" "xfs_repair:"   "$( [ "$XFSREPAIR_AVAILABLE" = true ] && echo -e "${GREEN}✔ ready${RESET}" || echo -e "${YELLOW}✖ unavailable${RESET}" )"
    echo ""
}

show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'BANNER'
  ███████╗ ██████╗ ██████╗ ███████╗███╗   ██╗███████╗██╗ ██████╗
  ██╔════╝██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║██╔════╝
  █████╗  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║███████╗██║██║
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║╚██╗██║╚════██║██║██║
  ██║     ╚██████╔╝██║  ██║███████╗██║ ╚████║███████║██║╚██████╗
  ╚═╝      ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝╚══════╝╚═╝ ╚═════╝
BANNER
    echo -e "${RESET}${BOLD}${BLUE}        Drive Corruption & Malware Forensic Analyser${RESET}"
    echo -e "${DIM}        $(date '+%A, %d %B %Y  %H:%M:%S')  |  Reports: $REPORTS_DIR${RESET}"
    sep; echo ""
}

root_warning() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}${BOLD}  ⚠  Not running as root — some checks need sudo. Re-run: sudo $0${RESET}"
        sleep 2
    fi
}

list_drives() {
    log "${BOLD}${CYAN}▸ Detecting drives…${RESET}"; echo ""
    mapfile -t DRIVES < <(lsblk -dpno NAME,SIZE,TYPE,VENDOR,MODEL,TRAN 2>/dev/null | grep -Ev 'loop|ram' | grep -E 'disk|rom')
    [ ${#DRIVES[@]} -eq 0 ] && { log "${RED}✖  No drives detected.${RESET}"; exit 1; }
    printf "  ${BOLD}%-4s %-12s %-7s %-6s %-11s %s${RESET}\n" "#" "Device" "Size" "Type" "Transport" "Model"
    sep
    local idx=1; DRIVE_PATHS=()
    for drv in "${DRIVES[@]}"; do
        local dev size type vendor model tran color
        read -r dev size type vendor model tran <<< "$drv"
        color=$RESET; [[ "$tran" == "usb" ]] && color=$YELLOW
        printf "  ${BOLD}%-4s${RESET}${color}%-12s %-7s %-6s %-11s %s %s${RESET}\n" \
            "$idx)" "$dev" "$size" "$type" "${tran:-N/A}" "$vendor" "$model"
        DRIVE_PATHS+=("$dev"); ((idx++))
    done; echo ""
}

select_drive() {
    local total=${#DRIVE_PATHS[@]}
    while true; do
        printf "  ${BOLD}${GREEN}Select drive [1-%s] or q to quit: ${RESET}" "$total"
        read -r choice
        [[ "$choice" =~ ^[qQ]$ ]] && { log "Exited."; exit 0; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            SELECTED_DRIVE="${DRIVE_PATHS[$((choice-1))]}"
            log "${BOLD}${CYAN}  ✔ Selected: ${YELLOW}$SELECTED_DRIVE${RESET}"; break
        else
            echo -e "  ${RED}Invalid — enter 1–$total${RESET}"
        fi
    done
}

do_mount() {
    local dev="$1" fstype="$2"
    local mnt="/tmp/forensic_mnt_$(basename "$dev")_$$"
    mkdir -p "$mnt"
    local opts="-o ro,noatime"
    local tried_types=()
    case "$fstype" in
        ntfs)       tried_types=("ntfs-3g" "ntfs") ;;
        vfat|fat*)  tried_types=("vfat") ;;
        exfat)      tried_types=("exfat") ;;
        ext*)       tried_types=("$fstype") ;;
        xfs)        tried_types=("xfs") ;;
        btrfs)      tried_types=("btrfs") ;;
        *)          tried_types=("") ;;
    esac
    tried_types+=("")

    for t in "${tried_types[@]}"; do
        local cmd
        [ -n "$t" ] && cmd="mount -t $t $opts" || cmd="mount $opts"
        if [ "$EUID" -ne 0 ]; then
            sudo $cmd "$dev" "$mnt" >/dev/null 2>&1
        else
            $cmd "$dev" "$mnt" >/dev/null 2>&1
        fi
        if mount | grep -q " $mnt "; then
            MOUNTED_BY_US+=("$mnt"); echo "$mnt"; return 0
        fi
    done
    rmdir "$mnt" 2>/dev/null; echo ""; return 1
}

do_unmount() {
    local dev="$1"
    if [ "$EUID" -ne 0 ]; then
        sudo umount "$dev" >/dev/null 2>&1 || sudo umount -l "$dev" >/dev/null 2>&1
    else
        umount "$dev" >/dev/null 2>&1 || umount -l "$dev" >/dev/null 2>&1
    fi
}

do_remount() {
    local dev="$1" mnt="$2"
    if [ "$EUID" -ne 0 ]; then
        sudo mount "$dev" "$mnt" >/dev/null 2>&1
    else
        mount "$dev" "$mnt" >/dev/null 2>&1
    fi
}

run_fsck() {
    local part="$1" fstype="$2"
    case "$fstype" in
        ext2|ext3|ext4)
            [ "$EUID" -ne 0 ] && sudo fsck.ext4 -n -v "$part" 2>&1 || fsck.ext4 -n -v "$part" 2>&1 ;;
        vfat|fat32|fat16)
            [ "$EUID" -ne 0 ] && sudo fsck.vfat -n -v "$part" 2>&1 || fsck.vfat -n -v "$part" 2>&1 ;;
        ntfs)
            if [ "$NTFSFIX_AVAILABLE" = true ]; then
                [ "$EUID" -ne 0 ] && sudo ntfsfix -n "$part" 2>&1 || ntfsfix -n "$part" 2>&1
            else
                [ "$EUID" -ne 0 ] && sudo fsck -n "$part" 2>&1 || fsck -n "$part" 2>&1
            fi ;;
        xfs)
            if [ "$XFSREPAIR_AVAILABLE" = true ]; then
                [ "$EUID" -ne 0 ] && sudo xfs_repair -n "$part" 2>&1 || xfs_repair -n "$part" 2>&1
            else
                echo "xfs_repair unavailable"
            fi ;;
        btrfs)
            if command -v btrfs &>/dev/null; then
                [ "$EUID" -ne 0 ] && sudo btrfs check --readonly "$part" 2>&1 || btrfs check --readonly "$part" 2>&1
            else
                echo "btrfs tools unavailable"
            fi ;;
        *)
            [ "$EUID" -ne 0 ] && sudo fsck -n "$part" 2>&1 || fsck -n "$part" 2>&1 ;;
    esac
}

check_mount_status() {
    echo ""; sep
    log "${BOLD}${BLUE}[1/5] MOUNT STATUS & PARTITION TABLE${RESET}"; sep

    spin_start "Reading partition table…"
    R_PARTITIONS=$(lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID "$SELECTED_DRIVE" 2>/dev/null)
    R_BLKID=$(blkid "${SELECTED_DRIVE}"* 2>/dev/null || echo "Not available")
    spin_stop "${GREEN}✔ Partition table read${RESET}"

    echo "$R_PARTITIONS"
    echo ""
    log "${DIM}blkid:${RESET}"; echo "$R_BLKID"; echo ""

    local mounted
    mounted=$(lsblk -lno NAME,MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null | awk '$2!="" {print "/dev/"$1" -> "$2}')
    if [ -n "$mounted" ]; then
        log "${YELLOW}⚠  Mounted partitions (will auto-unmount for checks):${RESET}"
        echo "$mounted"
        R_MOUNT_STATUS="Partitions were mounted — auto-unmounted for scanning"$'\n'"$mounted"
    else
        log "${GREEN}✔  No partitions mounted${RESET}"
        R_MOUNT_STATUS="All partitions unmounted at scan time"
    fi
}

check_smart() {
    echo ""; sep
    log "${BOLD}${BLUE}[2/5] S.M.A.R.T. HEALTH CHECK${RESET}"; sep

    if [ "$SMART_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  smartctl unavailable — skipped${RESET}"
        R_SMART_STATUS="SKIPPED — smartctl not available"; return
    fi

    spin_start "Running SMART health check…"
    if [ "$EUID" -ne 0 ]; then
        R_SMART_HEALTH=$(sudo smartctl -H "$SELECTED_DRIVE" 2>&1)
        R_SMART_ATTRS=$(sudo smartctl -A "$SELECTED_DRIVE" 2>/dev/null | grep -E "Reallocated|Pending|Uncorrectable|Power_On|Temperature|Seek_Error|Spin_Retry")
    else
        R_SMART_HEALTH=$(smartctl -H "$SELECTED_DRIVE" 2>&1)
        R_SMART_ATTRS=$(smartctl -A "$SELECTED_DRIVE" 2>/dev/null | grep -E "Reallocated|Pending|Uncorrectable|Power_On|Temperature|Seek_Error|Spin_Retry")
    fi

    if echo "$R_SMART_HEALTH" | grep -q "PASSED"; then
        spin_stop "${GREEN}✔  SMART: PASSED${RESET}"
        R_SMART_STATUS="PASSED — no drive failures detected"
    elif echo "$R_SMART_HEALTH" | grep -q "FAILED"; then
        spin_stop "${RED}✖  SMART: FAILED — drive at risk!${RESET}"
        R_SMART_STATUS="FAILED — drive hardware failure risk detected"
    else
        spin_stop "${YELLOW}⚠  SMART: undetermined${RESET}"
        R_SMART_STATUS="UNDETERMINED — could not confirm status"
    fi

    if [ -n "$R_SMART_ATTRS" ]; then
        echo "$R_SMART_ATTRS"
    else
        log "${DIM}  No key attributes available${RESET}"
        R_SMART_ATTRS="Not available"
    fi
}

check_filesystem() {
    echo ""; sep
    log "${BOLD}${BLUE}[3/5] FILESYSTEM INTEGRITY CHECK${RESET}"; sep

    mapfile -t PARTS < <(lsblk -lno NAME,TYPE "$SELECTED_DRIVE" 2>/dev/null | awk '$2=="part"{print "/dev/"$1}')
    [ ${#PARTS[@]} -eq 0 ] && { log "${YELLOW}⚠  No partitions found — using whole device${RESET}"; PARTS=("$SELECTED_DRIVE"); }

    R_FS_RESULTS=""
    local total=${#PARTS[@]} idx=0

    for part in "${PARTS[@]}"; do
        ((idx++))
        local fstype existing_mnt was_mounted=false
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null)
        existing_mnt=$(lsblk -lno MOUNTPOINT "$part" 2>/dev/null | awk 'NF{print;exit}')

        printf "\r\033[2K  ${CYAN}[%d/%d]${RESET} %s  ${DIM}(%s)${RESET}\n" "$idx" "$total" "$part" "${fstype:-unknown}"

        if [ -n "$existing_mnt" ]; then
            was_mounted=true
            printf "  ${YELLOW}⚠  Mounted at %s — unmounting…${RESET}\n" "$existing_mnt"
            do_unmount "$part"
            if mount | grep -q "^$part "; then
                log "  ${RED}✖  Cannot unmount $part — skipping${RESET}"
                R_FS_RESULTS+=$'\n'"Partition : $part"$'\n'"Verdict   : SKIPPED — could not unmount"$'\n'
                continue
            fi
            log "  ${GREEN}✔  Unmounted${RESET}"
        fi

        printf "  ${CYAN}⠿  Running %s check on %s…${RESET}\n" "${fstype:-generic}" "$part"

        local fsck_out fsck_verdict
        fsck_out=$(run_fsck "$part" "$fstype")
        echo "$fsck_out"

        if   echo "$fsck_out" | grep -qiE "clean|no problems|no errors|consistent|no modify"; then
            fsck_verdict="CLEAN — no errors detected"
            printf "  ${GREEN}✔  %s: %s${RESET}\n" "$part" "$fsck_verdict"
        elif echo "$fsck_out" | grep -qiE "error|corrupt|bad block|problem|would fix|inconsisten"; then
            fsck_verdict="ERRORS FOUND — corruption detected"
            printf "  ${RED}✖  %s: %s${RESET}\n" "$part" "$fsck_verdict"
        else
            fsck_verdict="COMPLETED — review output above"
            printf "  ${YELLOW}⚠  %s: %s${RESET}\n" "$part" "$fsck_verdict"
        fi

        if [ "$was_mounted" = true ] && [ -n "$existing_mnt" ]; then
            printf "  ${CYAN}↩  Re-mounting %s at %s…${RESET}\n" "$part" "$existing_mnt"
            do_remount "$part" "$existing_mnt" && log "  ${GREEN}✔  Re-mounted${RESET}" || log "  ${YELLOW}⚠  Re-mount failed — partition left unmounted${RESET}"
        fi

        R_FS_RESULTS+=$'\n'"Partition : $part"$'\n'"Filesystem: ${fstype:-unknown}"$'\n'"Verdict   : $fsck_verdict"$'\n'"Raw Output:"$'\n'"$fsck_out"$'\n'
        echo ""
    done
}

check_bad_sectors() {
    echo ""; sep
    log "${BOLD}${BLUE}[4/5] BAD SECTOR SCAN${RESET}"; sep

    if [ "$BADBLOCKS_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  badblocks unavailable — skipped${RESET}"
        R_BAD_SECTORS="SKIPPED — badblocks not available"; return
    fi

    printf "  ${BOLD}${GREEN}Run bad sector scan? Takes several minutes. [y/N]: ${RESET}"
    read -r do_bad
    if [[ ! "$do_bad" =~ ^[Yy]$ ]]; then
        log "${DIM}  Skipped${RESET}"; R_BAD_SECTORS="SKIPPED — user opted out"; return
    fi

    log "${CYAN}  Scanning $SELECTED_DRIVE for bad sectors (live output)…${RESET}"
    local tmp; tmp=$(mktemp)

    if [ "$EUID" -ne 0 ]; then
        sudo badblocks -sv "$SELECTED_DRIVE" 2>&1 | tee "$tmp"
    else
        badblocks -sv "$SELECTED_DRIVE" 2>&1 | tee "$tmp"
    fi

    local bad_out bad_count
    bad_out=$(cat "$tmp"); rm -f "$tmp"
    bad_count=$(echo "$bad_out" | grep -c "bad block" 2>/dev/null || echo 0)

    if [ "$bad_count" -gt 0 ]; then
        log "${RED}✖  Bad sectors found: $bad_count block(s)!${RESET}"
        R_BAD_SECTORS="FAILED — $bad_count bad block(s) on $SELECTED_DRIVE"$'\n'"$bad_out"
    else
        log "${GREEN}✔  No bad sectors detected${RESET}"
        R_BAD_SECTORS="PASSED — no bad sectors found"
    fi
}

check_viruses() {
    echo ""; sep
    log "${BOLD}${BLUE}[5/5] MALWARE / VIRUS SCAN${RESET}"; sep

    if [ "$CLAM_AVAILABLE" = false ]; then
        log "${YELLOW}⚠  ClamAV unavailable — skipped${RESET}"
        R_VIRUS_STATUS="SKIPPED — ClamAV not available"; return
    fi

    local scan_path
    scan_path=$(lsblk -lno MOUNTPOINT "$SELECTED_DRIVE" 2>/dev/null | awk 'NF{print;exit}')

    if [ -z "$scan_path" ]; then
        log "${YELLOW}  Drive not mounted — attempting auto-mount…${RESET}"
        local fstype
        fstype=$(blkid -o value -s TYPE "${SELECTED_DRIVE}1" 2>/dev/null)
        [ -z "$fstype" ] && fstype=$(blkid -o value -s TYPE "$SELECTED_DRIVE" 2>/dev/null)

        spin_start "Mounting ${SELECTED_DRIVE}…"
        scan_path=$(do_mount "${SELECTED_DRIVE}1" "$fstype" 2>/dev/null)
        [ -z "$scan_path" ] && scan_path=$(do_mount "$SELECTED_DRIVE" "$fstype" 2>/dev/null)
        spin_stop

        if [ -n "$scan_path" ]; then
            log "${GREEN}  ✔  Mounted at $scan_path${RESET}"
        else
            log "${YELLOW}  ⚠  Auto-mount failed.${RESET}"
            printf "  ${BOLD}${GREEN}Enter mount point (or Enter to skip): ${RESET}"
            read -r scan_path
            if [ -z "$scan_path" ]; then
                log "${DIM}  Skipped${RESET}"
                R_VIRUS_STATUS="SKIPPED — could not mount drive"; return
            fi
        fi
    fi

    if [ ! -d "$scan_path" ]; then
        log "${YELLOW}⚠  Path '$scan_path' does not exist — skipping${RESET}"
        R_VIRUS_STATUS="SKIPPED — path does not exist"; return
    fi

    R_VIRUS_PATH="$scan_path"
    log "${CYAN}  Scanning $scan_path (live output)…${RESET}"
    echo ""

    local tmp; tmp=$(mktemp)
    clamscan -r --bell -i --stdout "$scan_path" 2>&1 | tee "$tmp"

    local clam_out
    clam_out=$(cat "$tmp"); rm -f "$tmp"

    R_INFECTED_COUNT=$(echo "$clam_out" | grep "^Infected files:" | awk '{print $3}')
    R_INFECTED_COUNT="${R_INFECTED_COUNT:-0}"
    local scanned known
    scanned=$(echo "$clam_out" | grep "^Scanned files:" | awk '{print $3}')
    known=$(echo "$clam_out" | grep "Known viruses:"  | awk '{print $3}')

    echo ""
    if [ "$R_INFECTED_COUNT" = "0" ]; then
        log "${GREEN}✔  Clean — no malware detected${RESET}"
        R_VIRUS_STATUS="CLEAN — no infected files found"
    else
        log "${RED}✖  INFECTED: $R_INFECTED_COUNT file(s) — see report!${RESET}"
        R_VIRUS_STATUS="INFECTED — $R_INFECTED_COUNT file(s) found"
        R_INFECTED_FILES=$(echo "$clam_out" | grep "FOUND")
    fi
    R_VIRUS_SUMMARY="Scanned files  : ${scanned:-N/A}"$'\n'"Known viruses  : ${known:-N/A}"$'\n'"Infected files : $R_INFECTED_COUNT"
}

write_report() {
    local end_time; end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local drive_model drive_size drive_tran drive_serial
    drive_model=$(lsblk -dno MODEL "$SELECTED_DRIVE" 2>/dev/null | xargs)
    drive_size=$(lsblk  -dno SIZE  "$SELECTED_DRIVE" 2>/dev/null | xargs)
    drive_tran=$(lsblk  -dno TRAN  "$SELECTED_DRIVE" 2>/dev/null | xargs)
    if [ "$EUID" -ne 0 ]; then
        drive_serial=$(sudo smartctl -i "$SELECTED_DRIVE" 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | xargs)
    else
        drive_serial=$(smartctl -i "$SELECTED_DRIVE" 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | xargs)
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
        echo "  Tool Version  : Forensic Drive Analyser v2.1"
        echo ""
        rsep
        echo "  SECTION 1 — TARGET DRIVE IDENTIFICATION"
        rsep; echo ""
        echo "  Device Path   : $SELECTED_DRIVE"
        echo "  Model         : ${drive_model:-Not available}"
        echo "  Capacity      : ${drive_size:-Not available}"
        echo "  Interface     : ${drive_tran:-Not available}"
        echo "  Serial Number : ${drive_serial:-Not available (run as root)}"
        echo ""
        echo "  Partition Layout:"
        echo "$R_PARTITIONS" | sed 's/^/    /'
        echo ""
        echo "  Block Device Identifiers:"
        echo "$R_BLKID" | sed 's/^/    /'
        echo ""
        echo "  Mount Status at Scan Time:"
        echo "    $R_MOUNT_STATUS"
        echo ""
        rsep
        echo "  SECTION 2 — S.M.A.R.T. HEALTH ASSESSMENT"
        rsep; echo ""
        echo "  Overall Verdict: $R_SMART_STATUS"
        echo ""
        if [ -n "$R_SMART_ATTRS" ] && [ "$R_SMART_ATTRS" != "Not available" ]; then
            echo "  Key SMART Attributes:"
            echo "$R_SMART_ATTRS" | sed 's/^/    /'
            echo ""
            echo "  Attribute Guide:"
            echo "    Reallocated_Sector_Ct  — Remapped bad sectors. Non-zero = physical damage."
            echo "    Current_Pending_Sector — Sectors awaiting remap. Non-zero = instability."
            echo "    Offline_Uncorrectable  — Sectors that failed correction. Any value = concern."
            echo "    Seek_Error_Rate        — Read/write head positioning failures."
            echo "    Spin_Retry_Count       — Failed spindle starts. Non-zero = motor stress."
        elif [ "$R_SMART_STATUS" != "SKIPPED — smartctl not available" ]; then
            echo "  Full SMART Output:"
            echo "$R_SMART_HEALTH" | sed 's/^/    /'
        else
            echo "  smartctl not available. Install smartmontools for drive health monitoring."
        fi
        echo ""
        rsep
        echo "  SECTION 3 — FILESYSTEM INTEGRITY ANALYSIS"
        rsep; echo ""
        [ -n "$R_FS_RESULTS" ] && echo "$R_FS_RESULTS" | sed 's/^/  /' || echo "  No filesystem results recorded."
        echo ""
        rsep
        echo "  SECTION 4 — BAD SECTOR SURFACE SCAN"
        rsep; echo ""
        echo "  Verdict: $R_BAD_SECTORS"
        echo ""
        echo "  Note: Even a single bad sector warrants immediate backup and replacement."
        echo ""
        rsep
        echo "  SECTION 5 — MALWARE & VIRUS SCAN"
        rsep; echo ""
        echo "  Scanner       : ClamAV"
        echo "  Scanned Path  : ${R_VIRUS_PATH:-N/A}"
        echo "  Verdict       : $R_VIRUS_STATUS"
        echo ""
        [ -n "$R_VIRUS_SUMMARY" ] && { echo "  Scan Statistics:"; echo "$R_VIRUS_SUMMARY" | sed 's/^/    /'; echo ""; }
        if [ -n "$R_INFECTED_FILES" ]; then
            echo "  Infected Files:"
            echo "$R_INFECTED_FILES" | sed 's/^/    /'
            echo ""
            echo "  ACTION REQUIRED: Quarantine or delete all listed files immediately."
        fi
        echo ""
        rsep
        echo "  SECTION 6 — SUMMARY & RISK ASSESSMENT"
        rsep; echo ""
        echo "  Drive            : $SELECTED_DRIVE (${drive_model:-unknown})"
        echo "  SMART Health     : $R_SMART_STATUS"
        echo "  Filesystem Check : $([ -n "$R_FS_RESULTS" ] && echo "Performed — see Section 3" || echo "Not performed")"
        echo "  Bad Sectors      : $R_BAD_SECTORS"
        echo "  Malware          : $R_VIRUS_STATUS"
        echo ""

        local risk_level="LOW" risk_notes=""
        echo "$R_SMART_STATUS"  | grep -qi "FAILED"       && { risk_level="CRITICAL"; risk_notes+=$'\n'"  - SMART failure: drive at risk of imminent failure."; }
        echo "$R_BAD_SECTORS"   | grep -qi "FAILED"       && { risk_level="HIGH";     risk_notes+=$'\n'"  - Bad sectors confirmed: physical media damage."; }
        echo "$R_FS_RESULTS"    | grep -qi "ERRORS FOUND" && { [ "$risk_level" = "LOW" ] && risk_level="MEDIUM"; risk_notes+=$'\n'"  - Filesystem corruption on one or more partitions."; }
        echo "$R_VIRUS_STATUS"  | grep -qi "INFECTED"     && { [ "$risk_level" = "LOW" ] && risk_level="HIGH"; risk_notes+=$'\n'"  - Malware: $R_INFECTED_COUNT infected file(s) found."; }

        echo "  Risk Level: $risk_level"
        if [ -n "$risk_notes" ]; then
            echo ""; echo "  Issues Detected:"; echo "$risk_notes"
        else
            echo ""; echo "  No critical issues identified."
        fi
        echo ""
        [ -n "$R_TOOLS_MISSING" ] && { echo "  Unavailable Tools:$R_TOOLS_MISSING"; echo "  Re-run with all tools installed for complete results."; echo ""; }
        rsep
        echo "  END OF REPORT"
        rsep; echo ""
        echo "  All checks performed READ-ONLY. No data was modified on the target drive."
        echo "  Report: $REPORT_FILE"
        echo ""
    } > "$REPORT_FILE"
}

show_summary() {
    cleanup_mounts
    write_report
    echo ""; sep
    log "${BOLD}${MAGENTA}  FORENSIC ANALYSIS COMPLETE${RESET}"; sep
    log "  Drive    : ${YELLOW}$SELECTED_DRIVE${RESET}"
    log "  Finished : $(date '+%Y-%m-%d %H:%M:%S')"
    log "  Report   : ${CYAN}$REPORT_FILE${RESET}"
    sep; echo ""
}

main() {
    show_banner
    root_warning
    check_deps
    list_drives
    select_drive
    echo ""; log "${BOLD}${MAGENTA}▸ Analysing ${YELLOW}$SELECTED_DRIVE${MAGENTA}…${RESET}"
    check_mount_status
    check_smart
    check_filesystem
    check_bad_sectors
    check_viruses
    show_summary
}

main "$@"
