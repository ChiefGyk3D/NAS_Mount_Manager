#!/bin/bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# NAS Mount Script - On-demand mounting/unmounting of NAS shares
# Configurable via CLI flags, config file, or environment variables

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${NAS_CONFIG:-$SCRIPT_DIR/nas.conf}"

# Defaults (overridden by config file, then CLI flags)
NAS_IP="${NAS_IP:-192.168.1.10}"
MOUNT_BASE="${NAS_MOUNT_BASE:-/mnt/nas}"
SYMLINK_PATH="${NAS_SYMLINK:-$HOME/nas}"
NAS_USER="${NAS_USER:-}"
NAS_PASS="${NAS_PASS:-}"
SHARES="${NAS_SHARES:-}"
PROTOCOL="${NAS_PROTOCOL:-smb}"       # smb or nfs
SMB_VERSION="${NAS_SMB_VERSION:-3.0}"
NFS_VERSION="${NAS_NFS_VERSION:-4}"
MOUNT_OPTS="${NAS_MOUNT_OPTS:-}"
TIMEOUT=${NAS_TIMEOUT:-30}
EXCLUDE_SHARES="${NAS_EXCLUDE_SHARES:-}"
CACHE_TIME=${NAS_CACHE_TIME:-10}
RSIZE=${NAS_RSIZE:-4194304}
WSIZE=${NAS_WSIZE:-4194304}
MAX_CREDITS=${NAS_MAX_CREDITS:-128}
NFS_NCONNECT=${NAS_NFS_NCONNECT:-0}
NFS_TIMEO=${NAS_NFS_TIMEO:-150}
NFS_RETRANS=${NAS_NFS_RETRANS:-3}

# Load config file if it exists
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VERSION="2.3.0"
DISCOVERED_SHARES=""
DRY_RUN=false
NO_COLOR=${NO_COLOR:-false}

# Disable colors if requested or not a terminal
if [[ "$NO_COLOR" == "true" ]] || [[ ! -t 1 ]]; then
    GREEN='' RED='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# ── Protocol Helpers ──────────────────────────────────────────────────────────

# Return the share source string for the current protocol
# SMB: //IP/share   NFS: IP:/share
share_source() {
    local ip="$1" share="$2"
    if [[ "$PROTOCOL" == "nfs" ]]; then
        echo "$ip:/$share"
    else
        echo "//$ip/$share"
    fi
}

# Return the default mount options for the current protocol (no credentials)
default_mount_opts() {
    if [[ "$PROTOCOL" == "nfs" ]]; then
        echo "iocharset=utf8,nofail"
    else
        echo "iocharset=utf8,file_mode=0775,dir_mode=0775,nofail"
    fi
}

# Return the fstab filesystem type for the current protocol
fstab_fstype() {
    if [[ "$PROTOCOL" == "nfs" ]]; then
        echo "nfs"
    else
        echo "cifs"
    fi
}

# Validate the PROTOCOL variable
validate_protocol() {
    case "$PROTOCOL" in
        smb|nfs) ;;
        *)
            echo -e "${RED}Error: --protocol must be 'smb' or 'nfs' (got '$PROTOCOL')${NC}" >&2
            exit 1
            ;;
    esac
}

# ── Fstab Helpers ────────────────────────────────────────────────────────────

# Get all fstab entries for a given NAS IP
get_fstab_entries() {
    local ip="$1"
    if [[ "$PROTOCOL" == "nfs" ]]; then
        grep -v '^#' /etc/fstab 2>/dev/null | grep "$ip:/" || true
    else
        grep -v '^#' /etc/fstab 2>/dev/null | grep "//$ip/" || true
    fi
}

# Check if a specific share is already in fstab
is_in_fstab() {
    local ip="$1" share="$2"
    if [[ "$PROTOCOL" == "nfs" ]]; then
        # NFS format: IP:/share followed by whitespace
        grep -qE "$ip:/$share[[:space:]]" /etc/fstab 2>/dev/null
    else
        # SMB format: //ip/share followed by whitespace
        # Anchor match to avoid substring matches (e.g. "home" must not match "homes")
        grep -qE "//$ip/$share[[:space:]]" /etc/fstab 2>/dev/null
    fi
}

# Show fstab status for current NAS
show_fstab_status() {
    local entries
    entries=$(get_fstab_entries "$NAS_IP")
    if [ -n "$entries" ]; then
        echo -e "  ${BOLD}Fstab entries for $NAS_IP:${NC}"
        while IFS= read -r line; do
            local share
            if [[ "$PROTOCOL" == "nfs" ]]; then
                share=$(echo "$line" | awk '{print $1}' | sed "s|$NAS_IP:/||")
            else
                share=$(echo "$line" | awk '{print $1}' | sed "s|//$NAS_IP/||")
            fi
            local mp
            mp=$(echo "$line" | awk '{print $2}')
            local opts
            opts=$(echo "$line" | awk '{print $4}')
            if echo "$opts" | grep -q "noauto"; then
                echo -e "    ${CYAN}◆ $share${NC} → $mp ${YELLOW}(on-demand)${NC}"
            else
                echo -e "    ${CYAN}◆ $share${NC} → $mp ${GREEN}(auto-mount)${NC}"
            fi
        done <<< "$entries"
        return 0
    fi
    return 1
}

# ── Fstab Management ────────────────────────────────────────────────────────

# Get ALL fstab entries for the NAS IP (both protocols), one per line
# Returns raw fstab lines. Includes comment-preceded entries if they match.
get_all_nas_fstab_entries() {
    local ip="$1"
    grep -n "^[^#].*${ip}[:/]" /etc/fstab 2>/dev/null || true
}

# List fstab entries for the NAS with numbered display
fstab_list() {
    local ip="$NAS_IP"
    local entries
    entries=$(get_all_nas_fstab_entries "$ip")

    if [ -z "$entries" ]; then
        echo -e "  ${YELLOW}No fstab entries found for $ip${NC}"
        return 1
    fi

    echo -e "  ${BOLD}Fstab entries for $ip:${NC}"
    echo ""
    local idx=0
    while IFS= read -r raw_line; do
        ((idx++))
        local lineno="${raw_line%%:*}"
        local line="${raw_line#*:}"
        local src mp fstype opts
        src=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $2}')
        fstype=$(echo "$line" | awk '{print $3}')
        opts=$(echo "$line" | awk '{print $4}')

        # Extract share name from source
        local share
        if [[ "$src" == //* ]]; then
            share=$(echo "$src" | sed "s|//$ip/||")
        else
            share=$(echo "$src" | sed "s|$ip:/||")
        fi

        # Detect mount mode
        local mode="${GREEN}auto-mount${NC}"
        if echo "$opts" | grep -q "noauto"; then
            mode="${YELLOW}on-demand${NC}"
        fi

        echo -e "    ${CYAN}[$idx]${NC}  ${BOLD}$share${NC}"
        echo -e "         Source:  $src"
        echo -e "         Mount:   $mp"
        echo -e "         Type:    $fstype"
        echo -e "         Mode:    $mode"
        # Show a compact view of key options
        local key_opts=""
        for opt in soft hard vers=* rsize=* wsize=* _netdev nofail; do
            local match
            match=$(echo ",$opts," | grep -oP "(?<=,)${opt}(?=,)" | head -1)
            [ -n "$match" ] && key_opts="${key_opts:+$key_opts, }$match"
        done
        # Extract vers= separately since glob doesn't work in grep -oP like that
        local vers_match
        vers_match=$(echo ",$opts," | grep -oP '(?<=,)vers=[^,]+(?=,)' | head -1)
        [ -n "$vers_match" ] && key_opts="${key_opts:+$key_opts, }$vers_match"
        [ -n "$key_opts" ] && echo -e "         Options: $key_opts"
        echo ""
    done <<< "$entries"
    echo -e "  Total: $idx entry/entries  (fstab lines shown above)"
    return 0
}

# Remove selected fstab entries for the NAS
fstab_remove() {
    local ip="$NAS_IP"
    local entries
    entries=$(get_all_nas_fstab_entries "$ip")

    if [ -z "$entries" ]; then
        echo -e "${YELLOW}No fstab entries found for $ip${NC}"
        return 0
    fi

    echo -e "${BOLD}Current fstab entries for $ip:${NC}"
    echo ""
    local -a line_numbers=()
    local -a share_names=()
    local idx=0
    while IFS= read -r raw_line; do
        ((idx++))
        local lineno="${raw_line%%:*}"
        local line="${raw_line#*:}"
        local src mp fstype
        src=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $2}')
        fstype=$(echo "$line" | awk '{print $3}')

        local share
        if [[ "$src" == //* ]]; then
            share=$(echo "$src" | sed "s|//$ip/||")
        else
            share=$(echo "$src" | sed "s|$ip:/||")
        fi

        line_numbers+=("$lineno")
        share_names+=("$share")
        echo -e "  ${CYAN}[$idx]${NC}  $share  →  $mp  ($fstype)"
    done <<< "$entries"

    echo ""
    echo "Enter numbers to remove (comma-separated), 'all' to remove all, or 'q' to cancel:"
    echo -n "  > "
    read -r selection

    [[ "$selection" =~ ^[Qq] ]] && { echo "Cancelled."; return 0; }

    local -a to_remove=()
    if [[ "$selection" == "all" ]]; then
        to_remove=("${line_numbers[@]}")
        echo ""
        echo -e "${YELLOW}Will remove ALL $idx fstab entries for $ip${NC}"
    else
        # Parse comma-separated indices
        IFS=',' read -ra indices <<< "$selection"
        for i in "${indices[@]}"; do
            i=$(echo "$i" | xargs)  # trim whitespace
            if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "$idx" ]; then
                to_remove+=("${line_numbers[$((i-1))]}")
                echo -e "  Will remove: ${BOLD}${share_names[$((i-1))]}${NC} (fstab line ${line_numbers[$((i-1))]})"
            else
                echo -e "  ${RED}Invalid selection: $i (skipping)${NC}"
            fi
        done
    fi

    if [ ${#to_remove[@]} -eq 0 ]; then
        echo -e "${YELLOW}Nothing selected to remove.${NC}"
        return 0
    fi

    echo ""
    echo -n "Confirm removal of ${#to_remove[@]} entry/entries? (y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "Cancelled."
        return 0
    fi

    # Backup fstab
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}✓ Backed up /etc/fstab${NC}"

    # Remove lines by line number (process in reverse order to keep line numbers stable)
    IFS=$'\n' read -ra sorted < <(printf '%s\n' "${to_remove[@]}" | sort -rn)
    for lineno in "${sorted[@]}"; do
        sudo sed -i "${lineno}d" /etc/fstab
    done
    echo -e "${GREEN}✓ Removed ${#to_remove[@]} fstab entry/entries${NC}"

    # Also remove associated .automount and .mount units from systemd
    sudo systemctl daemon-reload
    echo -e "${GREEN}✓ systemd reloaded${NC}"

    # Offer to unmount the removed shares
    echo ""
    echo -n "Unmount the removed shares now? (y/N): "
    read -r do_unmount
    if [[ "$do_unmount" =~ ^[Yy] ]]; then
        for i in "${!to_remove[@]}"; do
            # Find the share name — we stored indices earlier, map back
            for j in "${!line_numbers[@]}"; do
                if [[ "${line_numbers[$j]}" == "${to_remove[$i]}" ]]; then
                    local share="${share_names[$j]}"
                    local mp="$MOUNT_BASE/$share"
                    if mountpoint -q "$mp" 2>/dev/null; then
                        sudo umount "$mp" 2>/dev/null && \
                            echo -e "  ${GREEN}✓ Unmounted $share${NC}" || \
                            echo -e "  ${YELLOW}⊘ Could not unmount $share (may be busy)${NC}"
                    fi
                    # Stop the automount unit if it exists
                    local unit_name
                    unit_name=$(systemd-escape -p "$mp").automount
                    sudo systemctl stop "$unit_name" 2>/dev/null || true
                fi
            done
        done
    fi

    echo ""
    echo -e "${GREEN}Done.${NC} Run '$(basename "$0") status' to verify."
}

# Edit options on an existing fstab entry
fstab_edit() {
    local ip="$NAS_IP"
    local entries
    entries=$(get_all_nas_fstab_entries "$ip")

    if [ -z "$entries" ]; then
        echo -e "${YELLOW}No fstab entries found for $ip${NC}"
        return 0
    fi

    echo -e "${BOLD}Fstab entries for $ip:${NC}"
    echo ""
    local -a line_numbers=()
    local -a share_names=()
    local -a entry_lines=()
    local idx=0
    while IFS= read -r raw_line; do
        ((idx++))
        local lineno="${raw_line%%:*}"
        local line="${raw_line#*:}"
        local src mp fstype opts
        src=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $2}')
        fstype=$(echo "$line" | awk '{print $3}')
        opts=$(echo "$line" | awk '{print $4}')

        local share
        if [[ "$src" == //* ]]; then
            share=$(echo "$src" | sed "s|//$ip/||")
        else
            share=$(echo "$src" | sed "s|$ip:/||")
        fi

        line_numbers+=("$lineno")
        share_names+=("$share")
        entry_lines+=("$line")
        echo -e "  ${CYAN}[$idx]${NC}  $share  ($fstype)"
        echo -e "        Options: $opts"
        echo ""
    done <<< "$entries"

    echo "Select entry to edit (1-$idx), or 'q' to cancel:"
    echo -n "  > "
    read -r selection

    [[ "$selection" =~ ^[Qq] ]] && { echo "Cancelled."; return 0; }

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$idx" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        return 1
    fi

    local sel_idx=$((selection - 1))
    local sel_lineno="${line_numbers[$sel_idx]}"
    local sel_line="${entry_lines[$sel_idx]}"
    local sel_share="${share_names[$sel_idx]}"
    local sel_src sel_mp sel_fstype sel_opts sel_dump sel_pass
    sel_src=$(echo "$sel_line" | awk '{print $1}')
    sel_mp=$(echo "$sel_line" | awk '{print $2}')
    sel_fstype=$(echo "$sel_line" | awk '{print $3}')
    sel_opts=$(echo "$sel_line" | awk '{print $4}')
    sel_dump=$(echo "$sel_line" | awk '{print $5}')
    sel_pass=$(echo "$sel_line" | awk '{print $6}')

    echo ""
    echo -e "${BOLD}Editing: $sel_share${NC}"
    echo ""
    echo "What would you like to change?"
    echo "  1) Mount point     (current: $sel_mp)"
    echo "  2) Mount options   (current: $sel_opts)"
    echo "  3) Replace with fresh defaults (regenerate from current settings)"
    echo "  q) Cancel"
    echo ""
    echo -n "  > "
    read -r edit_choice

    case "$edit_choice" in
        1)
            echo -n "New mount point [$sel_mp]: "
            read -r new_mp
            new_mp="${new_mp:-$sel_mp}"
            local new_line="$sel_src  $new_mp  $sel_fstype  $sel_opts  ${sel_dump:-0}  ${sel_pass:-0}"
            sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
            sudo sed -i "${sel_lineno}s|.*|${new_line}|" /etc/fstab
            sudo mkdir -p "$new_mp"
            sudo chown "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "$new_mp"
            echo -e "${GREEN}✓ Updated mount point to $new_mp${NC}"
            ;;
        2)
            echo ""
            echo "Current options (one per line for readability):"
            echo "$sel_opts" | tr ',' '\n' | sed 's/^/    /'
            echo ""
            echo "Enter new options string (comma-separated), or press Enter to keep current:"
            echo -n "  > "
            read -r new_opts
            new_opts="${new_opts:-$sel_opts}"
            local new_line="$sel_src  $sel_mp  $sel_fstype  $new_opts  ${sel_dump:-0}  ${sel_pass:-0}"
            sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
            sudo sed -i "${sel_lineno}s|.*|${new_line}|" /etc/fstab
            echo -e "${GREEN}✓ Updated options for $sel_share${NC}"
            ;;
        3)
            local new_opts new_line
            if [[ "$sel_fstype" == "nfs" || "$sel_fstype" == "nfs4" ]]; then
                new_opts=$(build_nfs_fstab_opts)
            else
                local fstab_uid=${SUDO_UID:-$(id -u)}
                local fstab_gid=${SUDO_GID:-$(id -g)}
                local cred_file="/etc/nas-credentials"
                local smb_extra="${MOUNT_OPTS:-iocharset=utf8,file_mode=0775,dir_mode=0775,nofail}"
                new_opts="credentials=$cred_file,uid=$fstab_uid,gid=$fstab_gid,vers=$SMB_VERSION,actimeo=$CACHE_TIME,rsize=$RSIZE,wsize=$WSIZE,max_credits=$MAX_CREDITS,$smb_extra,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=10"
            fi
            new_line="$sel_src  $sel_mp  $sel_fstype  $new_opts  0  0"
            echo ""
            echo "New entry:"
            echo "  $new_line"
            echo ""
            echo -n "Apply? (y/N): "
            read -r apply
            if [[ "$apply" =~ ^[Yy] ]]; then
                sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
                sudo sed -i "${sel_lineno}s|.*|${new_line}|" /etc/fstab
                echo -e "${GREEN}✓ Regenerated fstab entry for $sel_share${NC}"
            else
                echo "Cancelled."
                return 0
            fi
            ;;
        q|Q)
            echo "Cancelled."
            return 0
            ;;
        *)
            echo -e "${RED}Invalid choice.${NC}"
            return 1
            ;;
    esac

    sudo systemctl daemon-reload
    echo -e "${GREEN}✓ systemd reloaded${NC}"
    echo ""
    echo -e "Run '$(basename "$0") status' to verify, or 'sudo mount -a' to activate changes."
}

# Interactive fstab management menu
fstab_manage() {
    echo -e "${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║        Fstab Entry Manager             ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""

    while true; do
        echo -e "${BOLD}Actions:${NC}"
        echo "  1) List fstab entries for $NAS_IP"
        echo "  2) Add new fstab entries (generate + install)"
        echo "  3) Remove fstab entries"
        echo "  4) Edit an fstab entry"
        echo "  q) Quit"
        echo ""
        echo -n "  > "
        read -r action

        echo ""
        case "$action" in
            1) fstab_list ;;
            2) generate_fstab ;;
            3) fstab_remove ;;
            4) fstab_edit ;;
            q|Q) echo "Done."; return 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
        echo ""
    done
}

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    echo -e "${BOLD}NAS Mount Manager${NC}"
    echo ""
    echo "Usage: $(basename "$0") [OPTIONS] COMMAND"
    echo ""
    echo "Commands:"
    echo "  mount,    m       Mount NAS shares"
    echo "  remount,  r       Unmount and re-mount all NAS shares"
    echo "  unmount,  u       Unmount all NAS shares"
    echo "  repair,   x       Detect and fix stale/broken mounts (automount-aware)"
    echo "  status,   s       Show current mount status"
    echo "  discover, d       Discover available shares (SMB or NFS)"
    echo "  fstab,    f       Generate /etc/fstab entries"
    echo "  fstab-manage      Interactive fstab manager (list/add/remove/edit)"
    echo "  fstab-remove      Remove fstab entries for NAS shares"
    echo "  fstab-edit        Edit mount options on an fstab entry"
    echo "  migrate           Migrate mounts from ~/nas to /mnt/nas (Flatpak fix)"
    echo "  setup,    w       Interactive setup wizard (discover + mount)"
    echo "  config,   c       Generate a config file interactively"
    echo "  help,     h       Show this help"
    echo ""
    echo "Options:"
    echo "  -i, --ip IP         NAS IP address (default: $NAS_IP)"
    echo "  --protocol TYPE     Protocol: smb or nfs (default: $PROTOCOL)"
    echo "  -u, --user USER     SMB username"
    echo "  -p, --pass PASS     SMB password"
    echo "  -m, --mount PATH    Mount base path (default: $MOUNT_BASE)"
    echo "  --symlink PATH      Convenience symlink path (default: $SYMLINK_PATH)"
    echo "  --no-symlink        Don't create ~/nas symlink"
    echo "  -s, --shares LIST   Comma-separated share names"
    echo "  -e, --exclude LIST  Comma-separated shares to skip (e.g. homes,photo)"
    echo "  -t, --timeout SEC   Connection timeout in seconds (default: $TIMEOUT)"
    echo "  --cache-time SEC    Attribute cache timeout in seconds (default: $CACHE_TIME)"
    echo "  --rsize BYTES       Read buffer size (default: $RSIZE / $((RSIZE/1048576))MB)"
    echo "  --wsize BYTES       Write buffer size (default: $WSIZE / $((WSIZE/1048576))MB)"
    echo "  --max-credits N     SMB3 max credits / request parallelism (default: $MAX_CREDITS)"
    echo "  --smb-version VER   SMB protocol version (default: $SMB_VERSION)"
    echo "  --nfs-version VER   NFS protocol version (default: $NFS_VERSION)"
    echo "  --nfs-nconnect N    NFS multi-connection count, 0=disabled (default: $NFS_NCONNECT)"
    echo "  --nfs-timeo DS      NFS timeout in deciseconds (default: $NFS_TIMEO)"
    echo "  --nfs-retrans N     NFS retransmission count (default: $NFS_RETRANS)"
    echo "  --dry-run           Show what would be done without doing it"
    echo "  --no-color          Disable colored output"
    echo "  --config FILE       Path to config file"
    echo "  --version           Show version"
    echo ""
    echo "Environment Variables:"
    echo "  NAS_IP, NAS_PROTOCOL, NAS_USER, NAS_PASS, NAS_MOUNT_BASE, NAS_SHARES,"
    echo "  NAS_SMB_VERSION, NAS_NFS_VERSION, NAS_MOUNT_OPTS, NAS_CONFIG, NAS_TIMEOUT,"
    echo "  NAS_EXCLUDE_SHARES, NAS_CACHE_TIME, NAS_RSIZE, NAS_WSIZE,"
    echo "  NAS_MAX_CREDITS, NAS_NFS_NCONNECT, NAS_NFS_TIMEO, NAS_NFS_RETRANS,"
    echo "  NO_COLOR"
    echo ""
    echo "Config File: $CONFIG_FILE"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") mount                            # Mount with defaults/config"
    echo "  $(basename "$0") --protocol nfs mount             # Mount NFS exports"
    echo "  $(basename "$0") -i 10.0.0.5 discover             # Discover shares on different NAS"
    echo "  $(basename "$0") --protocol nfs discover           # Discover NFS exports"
    echo "  $(basename "$0") -i 10.0.0.5 -u admin mount       # Mount SMB with specific IP and user"
    echo "  $(basename "$0") -s media,backups mount            # Mount specific shares only"
    echo "  $(basename "$0") -e homes,photo mount              # Mount all except excluded shares"
    echo "  $(basename "$0") setup                             # Interactive guided setup"
    echo "  $(basename "$0") fstab                             # Generate fstab entries"
    echo "  $(basename "$0") fstab-manage                      # Interactive fstab manager"
    echo "  $(basename "$0") fstab-remove                      # Remove fstab entries"
    echo "  $(basename "$0") fstab-edit                        # Edit an fstab entry"
}

check_deps() {
    local missing=()
    for cmd in mount umount; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ "$PROTOCOL" == "nfs" ]]; then
        if ! command -v mount.nfs &>/dev/null && ! [ -f /sbin/mount.nfs ]; then
            missing+=("nfs-common")
        fi
        if ! command -v showmount &>/dev/null; then
            missing+=("nfs-common (showmount)")
        fi
    else
        if ! command -v mount.cifs &>/dev/null && ! [ -f /sbin/mount.cifs ]; then
            missing+=("cifs-utils")
        fi
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing required packages: ${missing[*]}${NC}"
        if [[ "$PROTOCOL" == "nfs" ]]; then
            echo "Install with: sudo apt install nfs-common"
        else
            echo "Install with: sudo apt install cifs-utils smbclient"
        fi
        return 1
    fi
}

check_nas() {
    echo -n "Checking NAS at $NAS_IP... "
    if ping -c 1 -W 2 "$NAS_IP" &>/dev/null; then
        echo -e "${GREEN}reachable ✓${NC}"
        return 0
    else
        echo -e "${RED}unreachable ✗${NC}"
        return 1
    fi
}

# ── Credential Management ────────────────────────────────────────────────────

# Check if system keyring is available (GNOME Keyring / KDE Wallet)
has_keyring() {
    # Need secret-tool binary
    command -v secret-tool &>/dev/null || return 1
    # Need a D-Bus session bus (required for secret-tool to talk to keyring)
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 1
    # Quick check: can we reach the secrets service at all?
    # Wrap in timeout to avoid hanging if the keyring daemon is unresponsive
    timeout 3 secret-tool lookup service nas-mount-test key ping 2>/dev/null
    local rc=$?
    # rc=0: found (won't happen for this fake key)
    # rc=1: not found — but service IS reachable, so keyring is available
    # rc=124: timed out — service is unresponsive
    # rc>1: other error — service is unavailable
    [[ $rc -le 1 ]]
}

# Store password in system keyring
keyring_store() {
    local ip="$1" user="$2" pass="$3"
    if ! command -v secret-tool &>/dev/null; then
        echo -e "${YELLOW}  secret-tool not installed. Install with: sudo apt install libsecret-tools${NC}" >&2
        return 1
    fi
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        echo -e "${YELLOW}  No D-Bus session bus — keyring requires a desktop session.${NC}" >&2
        echo -e "${YELLOW}  If using SSH/TTY, start one with: eval \$(dbus-launch --sh-syntax)${NC}" >&2
        return 1
    fi
    echo "$pass" | timeout 5 secret-tool store --label="NAS $ip ($user)" \
        service nas-mount host "$ip" user "$user" 2>/dev/null
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo -e "${YELLOW}  Keyring daemon may not be running. Try: gnome-keyring-daemon --start --components=secrets${NC}" >&2
    fi
    return $rc
}

# Retrieve password from system keyring
keyring_lookup() {
    local ip="$1" user="$2"
    if has_keyring; then
        secret-tool lookup service nas-mount host "$ip" user "$user" 2>/dev/null
        return $?
    fi
    return 1
}

# Remove password from system keyring
keyring_clear() {
    local ip="$1" user="$2"
    if has_keyring; then
        secret-tool clear service nas-mount host "$ip" user "$user" 2>/dev/null
        return $?
    fi
    return 1
}

# Prompt for credentials only once, cache for session
# Priority: CLI flags → config file → keyring → interactive prompt
get_credentials() {
    if [ -z "$NAS_USER" ]; then
        echo ""
        echo -n "NAS username (Enter for guest): "
        read -r NAS_USER
    fi

    if [ -n "$NAS_USER" ] && [ -z "$NAS_PASS" ]; then
        # Try keyring first
        local keyring_pass
        keyring_pass=$(keyring_lookup "$NAS_IP" "$NAS_USER")
        if [ -n "$keyring_pass" ]; then
            NAS_PASS="$keyring_pass"
            echo -e "${GREEN}✓ Password retrieved from keyring${NC}"
            return 0
        fi

        # Fall back to interactive prompt
        echo -n "Password for $NAS_USER: "
        read -rs NAS_PASS
        echo ""

        # Offer to save to keyring
        if has_keyring && [ -n "$NAS_PASS" ]; then
            echo -n "Save password to system keyring? (y/N): "
            read -r save_kr
            if [[ "$save_kr" =~ ^[Yy] ]]; then
                if keyring_store "$NAS_IP" "$NAS_USER" "$NAS_PASS"; then
                    echo -e "${GREEN}✓ Password saved to keyring${NC}"
                fi
                # keyring_store already prints diagnostic messages on failure
            fi
        fi
    fi
}

# Create a temporary credentials file for mount (avoids password in /proc)
# Returns the path to the temp file — caller must clean up
create_temp_credentials() {
    local tmpdir="${XDG_RUNTIME_DIR:-/tmp}"
    local tmpfile
    tmpfile=$(mktemp "$tmpdir/.nas-creds-XXXXXX")
    chmod 600 "$tmpfile"
    cat > "$tmpfile" <<CREDEOF
username=${NAS_USER}
password=${NAS_PASS}
CREDEOF
    echo "$tmpfile"
}

build_cred_opts() {
    if [[ "$PROTOCOL" == "nfs" ]]; then
        build_nfs_opts
    else
        build_smb_opts
    fi
}

build_smb_opts() {
    local opts=""
    if [ -n "$NAS_USER" ]; then
        # Use temp credentials file instead of passing password on command line
        local cred_file
        cred_file=$(create_temp_credentials)
        TEMP_CRED_FILE="$cred_file"
        opts="credentials=$cred_file"
    else
        opts="guest"
    fi
    # Map ownership to the invoking user (SUDO_UID/GID if run via sudo, else current user)
    local mount_uid=${SUDO_UID:-$(id -u)}
    local mount_gid=${SUDO_GID:-$(id -g)}
    local extra_opts="${MOUNT_OPTS:-iocharset=utf8,file_mode=0775,dir_mode=0775,nofail}"
    opts="$opts,uid=$mount_uid,gid=$mount_gid,vers=$SMB_VERSION,actimeo=$CACHE_TIME,rsize=$RSIZE,wsize=$WSIZE,max_credits=$MAX_CREDITS,$extra_opts"
    echo "$opts"
}

build_nfs_opts() {
    local opts="vers=$NFS_VERSION,rsize=$RSIZE,wsize=$WSIZE,actimeo=$CACHE_TIME,hard,intr,timeo=$NFS_TIMEO,retrans=$NFS_RETRANS"
    # nconnect is only supported on NFSv4.1+ and Linux 5.3+ — only add if > 0
    if [ "$NFS_NCONNECT" -gt 0 ] 2>/dev/null; then
        opts="$opts,nconnect=$NFS_NCONNECT"
    fi
    local extra_opts="${MOUNT_OPTS:-nofail}"
    if [ -n "$extra_opts" ]; then
        opts="$opts,$extra_opts"
    fi
    echo "$opts"
}

# Build the NFS-specific fstab options string (reused by generate_fstab and install_fstab)
# Laptop-safe: _netdev (requires network), x-systemd.mount-timeout (caps hang time),
# soft (returns errors instead of hanging forever when NAS disappears)
build_nfs_fstab_opts() {
    local extra_opts="${MOUNT_OPTS:-nofail}"
    local opts="vers=$NFS_VERSION,rsize=$RSIZE,wsize=$WSIZE,actimeo=$CACHE_TIME,soft,timeo=$NFS_TIMEO,retrans=$NFS_RETRANS"
    if [ "$NFS_NCONNECT" -gt 0 ] 2>/dev/null; then
        opts="$opts,nconnect=$NFS_NCONNECT"
    fi
    opts="$opts,$extra_opts,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=10"
    echo "$opts"
}

# Clean up temp credentials file
cleanup_credentials() {
    if [ -n "${TEMP_CRED_FILE:-}" ] && [ -f "$TEMP_CRED_FILE" ]; then
        shred -u "$TEMP_CRED_FILE" 2>/dev/null || rm -f "$TEMP_CRED_FILE"
        TEMP_CRED_FILE=""
    fi
}

# Ensure cleanup on exit
trap cleanup_credentials EXIT INT TERM
TEMP_CRED_FILE=""
NO_SYMLINK=false

# ── Automount Unit Helper ────────────────────────────────────────────────────

# Start automount units for all fstab entries under MOUNT_BASE.
# `mount -a` alone does NOT activate x-systemd.automount units that have
# never been started — they remain "inactive dead" and folders appear empty.
# This function explicitly starts each .automount unit so the kernel's autofs
# triggers are registered and shares mount on first access.
start_automount_units() {
    local base="${1:-$MOUNT_BASE}"
    local started=0
    local fstab_mps
    fstab_mps=$(grep -v '^#' /etc/fstab 2>/dev/null \
        | grep 'x-systemd.automount' \
        | awk '{print $2}' \
        | grep "^$base/" || true)
    if [ -z "$fstab_mps" ]; then
        return 0
    fi
    while IFS= read -r mp; do
        [ -z "$mp" ] && continue
        local unit
        unit=$(systemd-escape -p "$mp").automount
        if systemctl is-active "$unit" &>/dev/null; then
            continue  # Already running
        fi
        if sudo systemctl start "$unit" 2>/dev/null; then
            echo -e "  ${GREEN}✓ Started $unit${NC}"
            ((started++))
        else
            echo -e "  ${YELLOW}⚠ Could not start $unit${NC}"
        fi
    done <<< "$fstab_mps"
    [ $started -gt 0 ] && echo -e "${GREEN}✓ $started automount unit(s) activated${NC}"
}

# Fully stop and disable old automount/mount units so they don't linger.
# Just `systemctl stop` leaves the unit loaded; if systemd re-reads fstab
# it can get confused. This does stop + reset-failed for both .automount
# and .mount units.
stop_old_units() {
    local mp="$1"
    local automount_unit mount_unit
    automount_unit=$(systemd-escape -p "$mp").automount
    mount_unit=$(systemd-escape -p "$mp").mount
    sudo systemctl stop "$automount_unit" 2>/dev/null || true
    sudo systemctl stop "$mount_unit" 2>/dev/null || true
    sudo umount -l "$mp" 2>/dev/null || true
    sudo systemctl reset-failed "$automount_unit" 2>/dev/null || true
    sudo systemctl reset-failed "$mount_unit" 2>/dev/null || true
}

# ── File Manager Bookmark Helper ─────────────────────────────────────────────

# Collect the list of NAS share mount points from fstab.
# Returns one absolute path per line.
_get_nas_share_paths() {
    local base="$MOUNT_BASE"
    grep -v '^#' /etc/fstab 2>/dev/null \
        | awk -v b="$base" '$2 ~ "^"b"/" {print $2}' || true
}

# Generate a human-readable label from a share directory name.
# e.g. "3dprinting" → "3dprinting", "vm_iso" → "Vm Iso", "80hd" → "80hd"
_share_label() {
    echo "$1" | sed 's/[_-]/ /g;s/\b\(.\)/\u\1/g'
}

# Regex pattern matching old NAS bookmark URIs that should be replaced.
_old_nas_uri_pattern() {
    local base="$MOUNT_BASE"
    # Matches: /mnt/*_nas (old layout), ~/nas/*, current MOUNT_BASE/*
    echo "^file:///mnt/[^/]*_nas$|^file://$HOME/nas/|^file://$base/"
}

# ── GTK bookmarks (GTK3 + GTK4) ──────────────────────────────────────

# Update a GTK-style bookmarks file (one "file:///path Label" per line).
# Used by Nautilus, Thunar, Nemo, Cosmic Files, and most GTK file managers.
_update_gtk_bookmarks() {
    local bookmark_file="$1"
    [ -f "$bookmark_file" ] || return 0

    local shares
    shares=$(_get_nas_share_paths)
    [ -z "$shares" ] && return 0

    local pattern
    pattern=$(_old_nas_uri_pattern)

    # Build new NAS bookmark lines
    local -a new_bookmarks=()
    while IFS= read -r mp; do
        [ -z "$mp" ] && continue
        local label
        label=$(_share_label "$(basename "$mp")")
        new_bookmarks+=("file://$mp $label")
    done <<< "$shares"

    # Keep non-NAS bookmarks
    local -a kept_bookmarks=()
    while IFS= read -r line; do
        local uri
        uri=$(echo "$line" | awk '{print $1}')
        if echo "$uri" | grep -qE "$pattern"; then
            continue
        fi
        kept_bookmarks+=("$line")
    done < "$bookmark_file"

    # Write: NAS bookmarks first, then the rest
    {
        for bm in "${new_bookmarks[@]}"; do echo "$bm"; done
        for bm in "${kept_bookmarks[@]}"; do echo "$bm"; done
    } > "$bookmark_file"
}

# ── KDE / XBEL bookmarks ─────────────────────────────────────────────

# Update the XBEL bookmark file used by KDE Dolphin, KDE file dialogs,
# and some other Qt-based file managers.
# Format: XML <bookmark href="file:///path"><title>Label</title>...</bookmark>
_update_xbel_bookmarks() {
    local xbel_file="$1"
    [ -f "$xbel_file" ] || return 0

    local shares
    shares=$(_get_nas_share_paths)
    [ -z "$shares" ] && return 0

    local pattern
    pattern=$(_old_nas_uri_pattern)
    local changed=false

    # Remove old NAS bookmarks from the XBEL file
    # Match <bookmark href="file:///mnt/*_nas"> or href containing old paths
    local old_mnt_pattern="/mnt/[^\"]*_nas\""
    local old_home_pattern="$HOME/nas/"
    local cur_base_pattern="$MOUNT_BASE/"
    if grep -qE "href=\"file://(${old_mnt_pattern}|${old_home_pattern}|${cur_base_pattern})" "$xbel_file" 2>/dev/null; then
        # Use sed to remove entire <bookmark>...</bookmark> blocks for old NAS paths
        # This handles the multi-line XML structure
        local tmpfile
        tmpfile=$(mktemp)
        awk -v old_mnt="$old_mnt_pattern" \
            -v old_home="$old_home_pattern" \
            -v cur_base="$cur_base_pattern" '
        BEGIN { skip=0 }
        /<bookmark / {
            if ($0 ~ "href=\"file:///mnt/[^\"]*_nas\"" ||
                $0 ~ "href=\"file://" old_home ||
                $0 ~ "href=\"file://" cur_base) {
                skip=1
                next
            }
        }
        /<\/bookmark>/ {
            if (skip) { skip=0; next }
        }
        { if (!skip) print }
        ' "$xbel_file" > "$tmpfile"
        cp "$tmpfile" "$xbel_file"
        rm -f "$tmpfile"
        changed=true
    fi

    # Add new NAS bookmarks before the closing </xbel> tag
    local -a entries=()
    local id_base
    id_base=$(date +%s)
    local idx=0
    while IFS= read -r mp; do
        [ -z "$mp" ] && continue
        # Skip if already present
        if grep -q "href=\"file://$mp\"" "$xbel_file" 2>/dev/null; then
            continue
        fi
        local label
        label=$(_share_label "$(basename "$mp")")
        entries+=(" <bookmark href=\"file://$mp\">
  <title>$label</title>
  <info>
   <metadata owner=\"http://freedesktop.org\">
    <bookmark:icon name=\"folder-network\"/>
   </metadata>
   <metadata owner=\"http://www.kde.org\">
    <ID>${id_base}/${idx}</ID>
    <isSystemItem>false</isSystemItem>
   </metadata>
  </info>
 </bookmark>")
        ((idx++))
        changed=true
    done <<< "$shares"

    if [ ${#entries[@]} -gt 0 ]; then
        # Insert before </xbel>
        local tmpfile
        tmpfile=$(mktemp)
        sed '/<\/xbel>/d' "$xbel_file" > "$tmpfile"
        for entry in "${entries[@]}"; do
            echo "$entry" >> "$tmpfile"
        done
        echo "</xbel>" >> "$tmpfile"
        cp "$tmpfile" "$xbel_file"
        rm -f "$tmpfile"
    fi

    $changed && return 0 || return 1
}

# ── Main bookmark updater ────────────────────────────────────────────

# Update file manager bookmarks across all supported desktop environments.
# Detects which bookmark files exist and updates each one.
update_bookmarks() {
    local updated=0

    # GTK3 (Nautilus, Thunar, Nemo, Cosmic Files, Caja, PCManFM)
    if [ -f "$HOME/.config/gtk-3.0/bookmarks" ]; then
        _update_gtk_bookmarks "$HOME/.config/gtk-3.0/bookmarks"
        ((updated++))
    fi

    # GTK4 (newer Nautilus, GNOME 42+)
    if [ -f "$HOME/.config/gtk-4.0/bookmarks" ]; then
        _update_gtk_bookmarks "$HOME/.config/gtk-4.0/bookmarks"
        ((updated++))
    fi

    # KDE / XBEL (Dolphin, KDE file dialogs, some Qt file managers)
    if [ -f "$HOME/.local/share/user-places.xbel" ]; then
        _update_xbel_bookmarks "$HOME/.local/share/user-places.xbel"
        ((updated++))
    fi

    if [ $updated -gt 0 ]; then
        echo -e "${GREEN}✓ Updated file manager bookmarks ($updated bookmark file(s))${NC}"
    fi
}

# ── Symlink Helper ───────────────────────────────────────────────────────────

# Create a convenience symlink from ~/nas (or $SYMLINK_PATH) to $MOUNT_BASE.
# This lets users type "~/nas/..." while the actual mount is outside /home,
# which avoids breaking Flatpak/bubblewrap (can't bind-mount autofs under /home).
ensure_symlink() {
    if $NO_SYMLINK; then
        return 0
    fi
    # Only create symlink when MOUNT_BASE is outside $HOME
    case "$MOUNT_BASE" in
        "$HOME"/*|"$HOME") return 0 ;;
    esac
    local target="$MOUNT_BASE"
    local link="$SYMLINK_PATH"
    if [ -L "$link" ]; then
        local current
        current=$(readlink -f "$link" 2>/dev/null)
        if [ "$current" = "$(readlink -f "$target" 2>/dev/null)" ]; then
            return 0  # Already correct
        fi
        echo -e "${YELLOW}Updating symlink $link → $target${NC}"
        rm -f "$link"
    elif [ -d "$link" ] && [ -z "$(ls -A "$link" 2>/dev/null)" ]; then
        # Empty directory at the symlink path — remove it to place the symlink
        rmdir "$link" 2>/dev/null
    elif [ -d "$link" ]; then
        # Non-empty directory — likely an old mount base with autofs mount points.
        # Try to stop automount units, unmount, and replace with symlink.
        echo -e "${YELLOW}$link is an existing directory (old mount base). Cleaning up...${NC}"
        local cleaned=true
        # Stop automount/mount units and unmount everything under this path
        while IFS= read -r mp; do
            [ -z "$mp" ] && continue
            local unit_automount unit_mount
            unit_automount=$(systemd-escape -p "$mp").automount
            unit_mount=$(systemd-escape -p "$mp").mount
            sudo systemctl stop "$unit_automount" 2>/dev/null || true
            sudo systemctl stop "$unit_mount" 2>/dev/null || true
            sudo umount -l "$mp" 2>/dev/null || true
        done < <(findmnt -rn -o TARGET 2>/dev/null | grep "^$link/" || true)
        # Remove all empty subdirectories
        find "$link" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        # Try to remove the directory itself
        if rmdir "$link" 2>/dev/null; then
            echo -e "${GREEN}✓ Cleaned up old directory $link${NC}"
        else
            echo -e "${YELLOW}⚠ Cannot replace $link with symlink — directory not empty after cleanup${NC}"
            echo -e "  ${CYAN}Try: ./mount-nas.sh migrate${NC}"
            return 0
        fi
    elif [ -e "$link" ]; then
        echo -e "${YELLOW}⚠ Cannot create symlink: $link already exists and is not a symlink or directory${NC}"
        return 0
    fi
    ln -s "$target" "$link" 2>/dev/null && \
        echo -e "${GREEN}✓ Created symlink $link → $target${NC}" || \
        echo -e "${YELLOW}⚠ Could not create symlink $link → $target${NC}"
}

# ── Migrate Command ──────────────────────────────────────────────────────────

# Migrate existing NAS mounts from $HOME/nas (or any path) to /mnt/nas.
# Stops automount units, updates fstab, creates new mount dirs, adds symlink.
migrate_mounts() {
    local old_base="${1:-$HOME/nas}"
    local new_base="$MOUNT_BASE"

    if [ "$old_base" = "$new_base" ]; then
        echo -e "${YELLOW}Old and new mount base are the same ($old_base) — nothing to migrate.${NC}"
        return 0
    fi

    echo -e "${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     NAS Mount Manager — Migration      ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  From: ${RED}$old_base${NC}"
    echo -e "  To:   ${GREEN}$new_base${NC}"
    echo ""

    # Find fstab entries pointing to the old base
    local old_entries
    old_entries=$(grep -n "^[^#]" /etc/fstab 2>/dev/null | grep "$old_base/" || true)
    if [ -z "$old_entries" ]; then
        echo -e "${YELLOW}No fstab entries found with mount points under $old_base${NC}"
        echo "Nothing to migrate."
        return 0
    fi

    echo -e "${BOLD}Fstab entries to migrate:${NC}"
    echo "────────────────────────────────────────"
    while IFS= read -r line; do
        local lineno="${line%%:*}"
        local content="${line#*:}"
        local mp
        mp=$(echo "$content" | awk '{print $2}')
        local share="${mp#$old_base/}"
        echo -e "  Line $lineno: ${CYAN}$share${NC}  ($mp → $new_base/$share)"
    done <<< "$old_entries"
    echo "────────────────────────────────────────"
    echo ""

    echo -n "Proceed with migration? (y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "Aborted."
        return 0
    fi
    echo ""

    # Backup fstab
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}✓ Backed up /etc/fstab${NC}"

    # Stop automount units for old paths (full cleanup: stop + reset-failed)
    echo -e "${BOLD}Stopping old automount units...${NC}"
    while IFS= read -r line; do
        local content="${line#*:}"
        local mp
        mp=$(echo "$content" | awk '{print $2}')
        stop_old_units "$mp"
        echo -e "  ${GREEN}✓ Stopped units for $mp${NC}"
    done <<< "$old_entries"

    # Update fstab: replace old_base with new_base in mount point column
    echo -e "${BOLD}Updating fstab entries...${NC}"
    # Use sed to replace the old base path with the new one (only in uncommented lines)
    sudo sed -i "s|$old_base/|$new_base/|g" /etc/fstab
    echo -e "${GREEN}✓ Updated mount points in /etc/fstab${NC}"

    # Create new mount directories
    local mount_uid=${SUDO_UID:-$(id -u)}
    local mount_gid=${SUDO_GID:-$(id -g)}
    sudo mkdir -p "$new_base"
    sudo chown "$mount_uid:$mount_gid" "$new_base"
    while IFS= read -r line; do
        local content="${line#*:}"
        local mp
        mp=$(echo "$content" | awk '{print $2}')
        local share="${mp#$old_base/}"
        sudo mkdir -p "$new_base/$share"
        sudo chown "$mount_uid:$mount_gid" "$new_base/$share"
        echo -e "  ${GREEN}✓ Created $new_base/$share${NC}"
    done <<< "$old_entries"

    # Unmount and clean up old mount dirs
    echo -e "${BOLD}Cleaning up old mount points...${NC}"
    while IFS= read -r line; do
        local content="${line#*:}"
        local mp
        mp=$(echo "$content" | awk '{print $2}')
        sudo umount -l "$mp" 2>/dev/null || true
        rmdir "$mp" 2>/dev/null || true
    done <<< "$old_entries"
    # Remove old base dir if empty
    if [ -d "$old_base" ] && [ -z "$(ls -A "$old_base" 2>/dev/null)" ]; then
        rmdir "$old_base" 2>/dev/null || true
    elif [ -d "$old_base" ]; then
        # Recursively remove empty parent dirs
        find "$old_base" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        rmdir "$old_base" 2>/dev/null || true
    fi

    # Create convenience symlink
    SYMLINK_PATH="$old_base"
    ensure_symlink
    echo ""

    # Reload systemd and activate
    echo -e "${BOLD}Activating new mounts...${NC}"
    sudo systemctl daemon-reload
    echo -e "${GREEN}✓ systemd reloaded${NC}"
    sudo mount -a 2>&1
    echo -e "${GREEN}✓ mount -a complete${NC}"

    # Start automount units (mount -a alone doesn't activate them)
    start_automount_units "$new_base"

    # Update file manager bookmarks
    update_bookmarks

    echo ""
    echo -e "${GREEN}Migration complete!${NC}"
    echo -e "  Mounts now at: ${CYAN}$new_base${NC}"
    if [ -L "$old_base" ]; then
        echo -e "  Symlink:       ${CYAN}$old_base → $new_base${NC}"
    fi
    echo -e "  Flatpak apps should now work without errors."
}

# ── Commands ─────────────────────────────────────────────────────────────────

# Check if a share name is in the exclusion list
is_excluded() {
    local share="$1"
    if [ -z "$EXCLUDE_SHARES" ]; then
        return 1
    fi
    local excluded
    IFS=',' read -ra excluded <<< "$EXCLUDE_SHARES"
    for ex in "${excluded[@]}"; do
        ex=$(echo "$ex" | xargs)
        if [ "$ex" = "$share" ]; then
            return 0
        fi
    done
    return 1
}

# Parse mount error output into a clean, short reason
parse_mount_error() {
    local output="$1"
    # Extract the core error reason, stripping the "Refer to..." noise
    local reason
    reason=$(echo "$output" | head -1 | sed 's/mount error([0-9]*): //')
    echo "$reason"
}

discover_shares() {
    if ! check_nas; then return 1; fi

    if [[ "$PROTOCOL" == "nfs" ]]; then
        discover_nfs_shares
    else
        discover_smb_shares
    fi
}

discover_nfs_shares() {
    echo "Discovering NFS exports on $NAS_IP..."

    # ── Method 1: showmount (uses RPC portmapper, port 111) ─────────────
    if command -v showmount &>/dev/null; then
        local output
        output=$(timeout "$TIMEOUT" showmount -e "$NAS_IP" 2>&1)
        local rc=$?

        if [ $rc -eq 0 ]; then
            # Parse showmount output (skip header line)
            # Format: /export/path  client-list
            local share_list
            share_list=$(echo "$output" | tail -n +2 | awk '{print $1}' | sed 's|^/||')

            if [ -n "$share_list" ]; then
                echo ""
                echo -e "${BOLD}Available NFS exports (via showmount):${NC}"
                while IFS= read -r line; do
                    local export_path allowed_hosts
                    export_path=$(echo "$line" | awk '{print $1}')
                    allowed_hosts=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
                    local sname
                    sname=$(echo "$export_path" | sed 's|^/||')
                    if is_in_fstab "$NAS_IP" "$sname"; then
                        echo -e "  ${CYAN}•${NC} $export_path  ${YELLOW}(fstab)${NC}  — allowed: $allowed_hosts"
                    else
                        echo -e "  ${CYAN}•${NC} $export_path  — allowed: $allowed_hosts"
                    fi
                done <<< "$(echo "$output" | tail -n +2)"
                echo ""
                DISCOVERED_SHARES="$share_list"
                return 0
            fi
        else
            echo -e "${YELLOW}showmount failed (RPC portmapper may be blocked).${NC}"
            echo -e "${YELLOW}Trying NFSv4 pseudo-root fallback...${NC}"
            echo ""
        fi
    else
        echo -e "${YELLOW}showmount not found — trying NFSv4 pseudo-root fallback...${NC}"
        echo ""
    fi

    # ── Method 2: NFSv4 pseudo-root mount (no portmapper needed) ────────
    # NFSv4 lets us mount the root export "/" and list top-level directories.
    # This works even when RPC/portmapper (port 111) is firewalled, which
    # is common on Synology, QNAP, TrueNAS, and many routers/firewalls.
    discover_nfs_v4_root
}

# Browse the NFSv4 pseudo-root to enumerate exports
discover_nfs_v4_root() {
    local tmpdir
    tmpdir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/.nas-nfs-probe-XXXXXX")

    echo "  Mounting NFSv4 pseudo-root ($NAS_IP:/) ..."
    local mount_output
    mount_output=$(sudo mount -t nfs -o vers=4,ro,noatime,timeo=50,retrans=1 \
        "$NAS_IP":/ "$tmpdir" 2>&1)
    local rc=$?

    if [ $rc -ne 0 ]; then
        rmdir "$tmpdir" 2>/dev/null
        echo -e "${RED}Could not mount NFSv4 pseudo-root.${NC}"
        echo -e "${RED}Raw output: $mount_output${NC}"
        echo ""
        echo -e "${YELLOW}Troubleshooting tips:${NC}"
        echo "  • Ensure NFS is enabled on your NAS and this host's IP is in the allowed list"
        echo "  • Check that port 2049 (NFS) is open:  nc -zv $NAS_IP 2049"
        echo "  • For showmount, port 111 (portmapper) must also be open"
        echo "  • On Synology: Control Panel → Shared Folder → NFS Permissions"
        echo "  • On TrueNAS: Sharing → Unix Shares (NFS)"
        echo ""
        return 1
    fi

    # List top-level directories (the exported shares)
    local share_list
    share_list=$(ls -1 "$tmpdir" 2>/dev/null | grep -v '^\.' | sort)

    sudo umount "$tmpdir" 2>/dev/null
    rmdir "$tmpdir" 2>/dev/null

    if [ -n "$share_list" ]; then
        echo ""
        echo -e "${BOLD}Available NFS exports (via NFSv4 pseudo-root):${NC}"
        while IFS= read -r sname; do
            [ -z "$sname" ] && continue
            if is_in_fstab "$NAS_IP" "$sname"; then
                echo -e "  ${CYAN}•${NC} /$sname  ${YELLOW}(fstab)${NC}"
            else
                echo -e "  ${CYAN}•${NC} /$sname"
            fi
        done <<< "$share_list"
        echo ""
        DISCOVERED_SHARES="$share_list"
        return 0
    else
        echo -e "${RED}NFSv4 root mounted but no exports found.${NC}"
        echo -e "${YELLOW}Your NAS may not export a browsable pseudo-root.${NC}"
        echo "  You can enter share names manually if you know them."
        echo ""
        return 1
    fi
}

discover_smb_shares() {
    if ! command -v smbclient &>/dev/null; then
        echo -e "${YELLOW}smbclient not installed. Install with: sudo apt install smbclient${NC}"
        return 1
    fi

    get_credentials

    echo "Discovering SMB shares on $NAS_IP..."
    local output
    if [ -n "$NAS_USER" ]; then
        # Use authentication file for smbclient to avoid password in process list
        local smb_auth
        smb_auth=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/.nas-smb-auth-XXXXXX")
        chmod 600 "$smb_auth"
        cat > "$smb_auth" <<SMBEOF
username=${NAS_USER}
password=${NAS_PASS}
SMBEOF
        output=$(timeout "$TIMEOUT" smbclient -L "//$NAS_IP" -A "$smb_auth" --option="client min protocol=SMB2" 2>&1 \
            | grep -v "smbXcli_negprot" | grep -v "Reconnecting with SMB1" | grep -v "Protocol negotiation" | grep -v "Unable to connect with SMB1")
        shred -u "$smb_auth" 2>/dev/null || rm -f "$smb_auth"
    else
        output=$(timeout "$TIMEOUT" smbclient -L "//$NAS_IP" -N --option="client min protocol=SMB2" 2>&1 \
            | grep -v "smbXcli_negprot" | grep -v "Reconnecting with SMB1" | grep -v "Protocol negotiation" | grep -v "Unable to connect with SMB1")
    fi

    local share_list
    share_list=$(echo "$output" | grep -i "Disk" | awk '{print $1}' | grep -Fv '$' | grep -v 'IPC')

    if [ -n "$share_list" ]; then
        echo ""
        echo -e "${BOLD}Available shares:${NC}"
        while IFS= read -r line; do
            local sname comment
            sname=$(echo "$line" | awk '{print $1}')
            comment=$(echo "$line" | sed 's/^[[:space:]]*[^ ]\+[[:space:]]\+Disk[[:space:]]*//')
            if is_in_fstab "$NAS_IP" "$sname"; then
                if [ -n "$comment" ]; then
                    echo -e "  ${CYAN}•${NC} $sname  ${YELLOW}(fstab)${NC}  ${NC}— $comment${NC}"
                else
                    echo -e "  ${CYAN}•${NC} $sname  ${YELLOW}(fstab)${NC}"
                fi
            else
                if [ -n "$comment" ]; then
                    echo -e "  ${CYAN}•${NC} $sname  — $comment"
                else
                    echo -e "  ${CYAN}•${NC} $sname"
                fi
            fi
        done <<< "$(echo "$output" | grep -i 'Disk' | grep -Fv '$' | grep -v 'IPC')"
        echo ""
        DISCOVERED_SHARES="$share_list"
        return 0
    else
        echo -e "${RED}No shares found. Raw output:${NC}"
        echo "$output" | head -20
        return 1
    fi
}

# ── Repair ────────────────────────────────────────────────────────────────────

repair_all() {
    echo -e "${BOLD}NAS Mount Repair${NC}"
    echo "═══════════════════════════════════════"
    echo ""

    # 1. Check NAS reachability
    echo -n "  Checking NAS at $NAS_IP … "
    if ping -c1 -W2 "$NAS_IP" &>/dev/null; then
        echo -e "${GREEN}reachable${NC}"
    else
        echo -e "${RED}unreachable${NC}"
        echo -e "  ${RED}Cannot repair — NAS is offline or unreachable.${NC}"
        echo -e "  ${YELLOW}Check your network connection and NAS power state.${NC}"
        return 1
    fi

    # 2. Collect fstab-managed NFS/SMB entries for this NAS
    local fstab_entries
    fstab_entries=$(get_fstab_entries "$NAS_IP")
    if [ -z "$fstab_entries" ]; then
        echo -e "  ${YELLOW}No fstab entries found for $NAS_IP — nothing to repair.${NC}"
        echo -e "  ${CYAN}Run '$(basename "$0") fstab' to generate entries first.${NC}"
        return 0
    fi

    local repaired=0
    local already_ok=0
    local failed=0
    local total=0

    echo ""
    echo -e "  ${BOLD}Checking shares…${NC}"
    echo ""

    while IFS= read -r fstab_line; do
        [ -z "$fstab_line" ] && continue
        local src mp fstype opts
        src=$(echo "$fstab_line" | awk '{print $1}')
        mp=$(echo "$fstab_line" | awk '{print $2}')
        fstype=$(echo "$fstab_line" | awk '{print $3}')
        opts=$(echo "$fstab_line" | awk '{print $4}')
        local share_name
        if [[ "$src" == //* ]]; then
            share_name=$(echo "$src" | sed "s|//$NAS_IP/||")
        else
            share_name=$(echo "$src" | sed "s|$NAS_IP:/||")
        fi
        ((total++))

        echo -n "    $share_name ($mp) … "

        # Determine if this is a systemd automount entry
        local uses_automount=false
        echo "$opts" | grep -q 'x-systemd.automount' && uses_automount=true

        # Derive the systemd unit names from the mount path
        local escaped_mp
        escaped_mp=$(systemd-escape --path "$mp")
        local automount_unit="${escaped_mp}.automount"
        local mount_unit="${escaped_mp}.mount"

        # Check if the mount is healthy: can we stat it within 3 seconds?
        local healthy=false
        if mountpoint -q "$mp" 2>/dev/null; then
            # Mount exists in kernel — test if it's responsive
            if timeout 3 stat "$mp" &>/dev/null; then
                healthy=true
            fi
        fi

        if $healthy; then
            echo -e "${GREEN}OK${NC}"
            ((already_ok++))
            continue
        fi

        # --- Needs repair ---
        echo -e "${YELLOW}stale or down${NC}"

        # Step A: Lazy-unmount any stale kernel mount
        if mountpoint -q "$mp" 2>/dev/null; then
            echo -n "      Lazy-unmounting stale mount … "
            if sudo umount -l "$mp" 2>/dev/null; then
                echo -e "${GREEN}done${NC}"
            else
                echo -e "${RED}failed${NC}"
            fi
        fi

        if $uses_automount; then
            # Step B: Reset and restart the automount unit
            echo -n "      Resetting systemd automount … "
            sudo systemctl stop "$automount_unit" 2>/dev/null
            sudo systemctl stop "$mount_unit" 2>/dev/null
            sudo systemctl reset-failed "$automount_unit" 2>/dev/null
            sudo systemctl reset-failed "$mount_unit" 2>/dev/null
            echo -e "${GREEN}done${NC}"

            echo -n "      Starting $automount_unit … "
            if sudo systemctl start "$automount_unit" 2>/dev/null; then
                echo -e "${GREEN}done${NC}"
            else
                echo -e "${RED}failed${NC}"
                ((failed++))
                continue
            fi

            # Step C: Trigger the automount by accessing the path
            echo -n "      Verifying access … "
            if timeout 10 ls "$mp" &>/dev/null; then
                echo -e "${GREEN}✓ working${NC}"
                ((repaired++))
            else
                echo -e "${RED}✗ still not responding${NC}"
                ((failed++))
            fi
        else
            # Non-automount: just remount directly
            echo -n "      Remounting $mp … "
            if sudo mount "$mp" 2>/dev/null; then
                echo -e "${GREEN}✓ mounted${NC}"
                ((repaired++))
            else
                echo -e "${RED}✗ mount failed${NC}"
                ((failed++))
            fi
        fi
    done <<< "$fstab_entries"

    echo ""
    echo "═══════════════════════════════════════"
    echo -e "  Total shares:  $total"
    echo -e "  ${GREEN}Already OK:    $already_ok${NC}"
    echo -e "  ${CYAN}Repaired:      $repaired${NC}"
    [ $failed -gt 0 ] && echo -e "  ${RED}Failed:        $failed${NC}"
    echo ""

    if [ $failed -gt 0 ]; then
        echo -e "  ${YELLOW}Some shares could not be repaired. Possible causes:${NC}"
        echo -e "    • NFS export permissions on the NAS (check allowed IPs/subnets)"
        echo -e "    • Share does not exist on the NAS anymore"
        echo -e "    • Firewall blocking NFS/SMB ports"
        echo -e "    • Try: sudo journalctl -u <mount-unit> --no-pager -n 20"
        return 1
    fi

    if [ $repaired -gt 0 ]; then
        echo -e "  ${GREEN}All shares repaired successfully!${NC}"
    else
        echo -e "  ${GREEN}All shares were already healthy — nothing to do.${NC}"
    fi
    return 0
}

mount_all() {
    check_deps || return 1
    if ! check_nas; then
        echo -e "${RED}Cannot mount — NAS is not reachable${NC}"
        return 1
    fi

    # NFS uses host-based auth, no credentials needed
    if [[ "$PROTOCOL" == "smb" ]]; then
        get_credentials
    fi

    # Get share list
    local share_list
    if [ -n "$SHARES" ]; then
        share_list=$(echo "$SHARES" | tr ',' '\n')
        echo -e "Using configured shares: ${CYAN}$SHARES${NC}"
    else
        echo "Discovering shares..."
        if discover_shares; then
            share_list="$DISCOVERED_SHARES"
        else
            echo ""
            echo -n "Enter share names manually (comma-separated): "
            read -r manual
            share_list=$(echo "$manual" | tr ',' '\n')
        fi
    fi

    if [ -z "$share_list" ]; then
        echo -e "${RED}No shares to mount${NC}"
        return 1
    fi

    mkdir -p "$MOUNT_BASE"

    local cred_opts
    cred_opts=$(build_cred_opts)
    local mounted=0
    local failed=0
    local denied=0
    local NEEDS_MIGRATION=false

    # Check for fstab-managed shares
    local fstab_entries
    fstab_entries=$(get_fstab_entries "$NAS_IP")
    local skipped=0
    local excluded=0

    echo ""
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue

        # Check exclusion list
        if is_excluded "$share"; then
            echo -e "  ${YELLOW}⊘ $share — excluded${NC}"
            ((excluded++))
            continue
        fi

        local mp="$MOUNT_BASE/$share"

        # Check if this share is managed by fstab
        if is_in_fstab "$NAS_IP" "$share"; then
            local fstab_mp
            local fstab_pattern
            if [[ "$PROTOCOL" == "nfs" ]]; then
                fstab_pattern="$NAS_IP:/$share[[:space:]]"
            else
                fstab_pattern="//$NAS_IP/$share[[:space:]]"
            fi
            fstab_mp=$(echo "$fstab_entries" | grep -E "$fstab_pattern" | awk '{print $2}' | head -1)

            # If the fstab mount point uses a different base than MOUNT_BASE,
            # the entry is stale (e.g. old ~/nas vs new /mnt/nas). Flag for migration.
            if [ -n "$fstab_mp" ] && [[ "$fstab_mp" != "$MOUNT_BASE"/* ]]; then
                echo -e "  ${YELLOW}⊘ $share — fstab entry uses old path: ${fstab_mp}${NC}"
                echo -e "    ${CYAN}Run './mount-nas.sh migrate' to move mounts to $MOUNT_BASE${NC}"
                ((skipped++))
                NEEDS_MIGRATION=true
                continue
            fi

            echo -e "  ${YELLOW}⊘ $share — managed by fstab (mount point: ${fstab_mp:-$mp})${NC}"
            echo -e "    ${CYAN}Use 'sudo mount $fstab_mp' or just 'cd $fstab_mp' if using automount${NC}"
            ((skipped++))
            continue
        fi

        local src
        src=$(share_source "$NAS_IP" "$share")

        if $DRY_RUN; then
            echo -e "  ${CYAN}[dry-run]${NC} Would mount $src → $mp"
            ((mounted++))
            continue
        fi

        mkdir -p "$mp"

        echo -n "  Mounting $src → $mp ... "

        if mountpoint -q "$mp" 2>/dev/null; then
            echo -e "${YELLOW}already mounted${NC}"
            ((mounted++))
            continue
        fi

        local mount_type
        mount_type=$(fstab_fstype)
        local mount_output
        local exit_code

        # NFS version negotiation — if "Protocol not supported", try lower versions
        if [[ "$PROTOCOL" == "nfs" ]]; then
            local nfs_versions_to_try=("$NFS_VERSION")
            # Build fallback list if user hasn't pinned a specific minor version
            case "$NFS_VERSION" in
                4|4.2) nfs_versions_to_try=(4.2 4.1 4.0 3) ;;
                4.1)   nfs_versions_to_try=(4.1 4.0 3) ;;
                4.0)   nfs_versions_to_try=(4.0 3) ;;
            esac

            local tried_version=""
            for try_ver in "${nfs_versions_to_try[@]}"; do
                local try_opts
                try_opts=$(echo "$cred_opts" | sed "s/vers=[^,]*/vers=$try_ver/")
                mount_output=$(sudo timeout "$TIMEOUT" mount -t "$mount_type" "$src" "$mp" -o "$try_opts" 2>&1)
                exit_code=$?
                tried_version="$try_ver"
                # If it worked or error is NOT "Protocol not supported", stop trying
                if [ $exit_code -eq 0 ] || ! echo "$mount_output" | grep -qi "protocol not supported"; then
                    break
                fi
                # Unmount in case partial mount occurred
                sudo umount "$mp" 2>/dev/null
            done

            # Update NFS_VERSION if a fallback worked (for subsequent mounts)
            if [ $exit_code -eq 0 ] && [ "$tried_version" != "$NFS_VERSION" ]; then
                echo -e "${GREEN}✓${NC} (NFSv$tried_version — v$NFS_VERSION not supported by server)"
                NFS_VERSION="$tried_version"
                # Rebuild cred_opts with the working version for remaining shares
                cred_opts=$(build_cred_opts)
                ((mounted++))
                continue
            fi
        else
            mount_output=$(sudo timeout "$TIMEOUT" mount -t "$mount_type" "$src" "$mp" -o "$cred_opts" 2>&1)
            exit_code=$?
        fi

        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}✓${NC}"
            ((mounted++))
        elif [ $exit_code -eq 124 ]; then
            echo -e "${RED}✗ timed out after ${TIMEOUT}s${NC}"
            ((failed++))
        elif echo "$mount_output" | grep -q "Permission denied\|error(13)"; then
            echo -e "${YELLOW}⊘ no access (permission denied)${NC}"
            ((denied++))
        else
            local reason
            reason=$(parse_mount_error "$mount_output")
            echo -e "${RED}✗ $reason${NC}"
            ((failed++))
        fi
    done <<< "$share_list"

    echo ""
    echo -e "${GREEN}Mounted: $mounted${NC}  ${RED}Failed: $failed${NC}"
    [ $denied -gt 0 ] && echo -e "${YELLOW}No access: $denied (permission denied — check NAS user permissions)${NC}"
    [ $skipped -gt 0 ] && echo -e "${YELLOW}Skipped: $skipped (fstab-managed)${NC}"
    [ $excluded -gt 0 ] && echo -e "${YELLOW}Excluded: $excluded${NC}"
    echo "Access shares at: $MOUNT_BASE/"

    if $NEEDS_MIGRATION; then
        echo ""
        echo -e "${BOLD}Some shares have fstab entries pointing to a different mount base.${NC}"
        echo -n "Run migration now to update them to $MOUNT_BASE? (y/N): "
        read -r do_migrate
        if [[ "$do_migrate" =~ ^[Yy] ]]; then
            migrate_mounts
            return $?
        else
            echo -e "  ${CYAN}You can run './mount-nas.sh migrate' later.${NC}"
        fi
    fi

    # Create convenience symlink (e.g. ~/nas → /mnt/nas)
    ensure_symlink
}

remount_all() {
    echo -e "${BOLD}Remounting NAS shares...${NC}"
    echo ""
    unmount_all
    echo ""
    mount_all
}

unmount_all() {
    echo "Unmounting NAS shares from $MOUNT_BASE ..."
    local count=0

    if [ ! -d "$MOUNT_BASE" ]; then
        echo -e "${YELLOW}No mount directory at $MOUNT_BASE${NC}"
        return 0
    fi

    for mp in "$MOUNT_BASE"/*/; do
        [ ! -d "$mp" ] && continue

        if mountpoint -q "${mp%/}" 2>/dev/null; then
            echo -n "  Unmounting ${mp%/} ... "
            if sudo umount -l "${mp%/}" 2>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                ((count++))
            else
                echo -e "${RED}✗ (may be busy — try closing files first)${NC}"
            fi
        fi
    done

    if [ $count -eq 0 ]; then
        echo "  Nothing was mounted"
    else
        echo -e "\n${GREEN}Unmounted $count share(s)${NC}"
    fi

    # Clean up empty mount directories
    for mp in "$MOUNT_BASE"/*/; do
        [ ! -d "$mp" ] && continue
        if ! mountpoint -q "${mp%/}" 2>/dev/null && [ -z "$(ls -A "${mp%/}" 2>/dev/null)" ]; then
            rmdir "${mp%/}" 2>/dev/null
        fi
    done
    # Remove base dir if empty
    rmdir "$MOUNT_BASE" 2>/dev/null || true
}

show_status() {
    echo -e "${BOLD}NAS Mount Status${NC}"
    echo "═══════════════════════════════════════"
    echo -e "  NAS IP:      ${CYAN}$NAS_IP${NC}"
    echo -e "  Protocol:    ${CYAN}${PROTOCOL^^}${NC}"
    echo -e "  Mount base:  ${CYAN}$MOUNT_BASE${NC}"
    echo -e "  Config:      ${CYAN}${CONFIG_FILE}${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "               ${GREEN}(loaded)${NC}"
    else
        echo -e "               ${YELLOW}(not found)${NC}"
    fi
    echo ""
    check_nas
    echo ""

    if [ ! -d "$MOUNT_BASE" ]; then
        echo "  No mount directory"
        return
    fi

    # Show fstab entries
    if ! show_fstab_status; then
        echo -e "  ${YELLOW}No fstab entries for $NAS_IP${NC}"
    fi
    echo ""

    local mounted=0
    echo -e "  ${BOLD}Active mounts:${NC}"

    # Find all mount points under MOUNT_BASE from our NAS (handles nested paths like volume1/share)
    # Use findmnt for reliable single-line output (mount wraps long NFS options across lines)
    local found_any=false
    while IFS= read -r mount_line; do
        [ -z "$mount_line" ] && continue
        local mount_src mount_mp
        mount_src=$(echo "$mount_line" | awk '{print $1}')
        mount_mp=$(echo "$mount_line" | awk '{print $2}')

        found_any=true
        local rel_path="${mount_mp#$MOUNT_BASE/}"
        local size
        size=$(df -h "$mount_mp" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 " used)"}')
        echo -e "    ${GREEN}● $rel_path${NC}  $size"
        ((mounted++))
    done <<< "$(findmnt -rn -o SOURCE,TARGET | grep "$NAS_IP")"

    # Also check for unmounted directories under MOUNT_BASE (only top-level share dirs)
    # Collect active mount points for comparison
    local active_mounts
    active_mounts=$(findmnt -rn -o TARGET | grep "^$MOUNT_BASE/")

    if [ -d "$MOUNT_BASE" ]; then
        while IFS= read -r mp; do
            [ -z "$mp" ] && continue
            # Skip directories that are inside an already-mounted path
            local inside_mount=false
            while IFS= read -r active_mp; do
                [ -z "$active_mp" ] && continue
                if [[ "$mp" == "$active_mp"/* ]] || [[ "$mp" == "$active_mp" ]]; then
                    inside_mount=true
                    break
                fi
            done <<< "$active_mounts"
            $inside_mount && continue

            if ! mountpoint -q "$mp" 2>/dev/null; then
                local rel_path="${mp#$MOUNT_BASE/}"
                # Only show if it looks like a share dir (not an intermediate dir with mounted children)
                local has_mounted_child=false
                for child in "$mp"/*/; do
                    [ -d "$child" ] && mountpoint -q "${child%/}" 2>/dev/null && has_mounted_child=true && break
                done
                if ! $has_mounted_child; then
                    found_any=true
                    echo -e "    ${RED}○ $rel_path${NC}  (not mounted)"
                fi
            fi
        done <<< "$(find "$MOUNT_BASE" -mindepth 1 -maxdepth 3 -type d 2>/dev/null)"
    fi

    [ $mounted -eq 0 ] && echo "    No shares currently mounted"
    return 0
}

generate_fstab() {
    # NFS uses host-based auth, no credentials needed
    if [[ "$PROTOCOL" == "smb" ]]; then
        get_credentials
    fi

    local share_list
    if [ -n "$SHARES" ]; then
        share_list=$(echo "$SHARES" | tr ',' '\n')
    else
        echo "Discovering shares to generate fstab entries..."
        if discover_shares; then
            share_list="$DISCOVERED_SHARES"
        else
            echo -n "Enter share names (comma-separated): "
            read -r manual
            share_list=$(echo "$manual" | tr ',' '\n')
        fi
    fi

    if [ -z "$share_list" ]; then
        echo -e "${RED}No shares to generate entries for${NC}"
        return 1
    fi

    local cred_file="/etc/nas-credentials"

    # Resolve the real user's UID/GID (works whether invoked directly or via sudo)
    local fstab_uid=${SUDO_UID:-$(id -u)}
    local fstab_gid=${SUDO_GID:-$(id -g)}

    echo ""
    echo -e "${BOLD}Generated /etc/fstab entries:${NC}"
    echo "────────────────────────────────────────────"
    echo ""

    local excluded_count=0
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        if is_excluded "$share"; then
            ((excluded_count++))
            continue
        fi
        local mp="$MOUNT_BASE/$share"
        local src
        src=$(share_source "$NAS_IP" "$share")
        local fstype
        fstype=$(fstab_fstype)
        local extra_opts="${MOUNT_OPTS:-nofail}"
        if [[ "$PROTOCOL" == "nfs" ]]; then
            local nfs_opts
            nfs_opts=$(build_nfs_fstab_opts)
            echo "$src  $mp  $fstype  $nfs_opts  0  0"
        else
            local smb_extra="${MOUNT_OPTS:-iocharset=utf8,file_mode=0775,dir_mode=0775,nofail}"
            echo "$src  $mp  $fstype  credentials=$cred_file,uid=$fstab_uid,gid=$fstab_gid,vers=$SMB_VERSION,actimeo=$CACHE_TIME,rsize=$RSIZE,wsize=$WSIZE,max_credits=$MAX_CREDITS,$smb_extra,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=10  0  0"
        fi
    done <<< "$share_list"

    [ $excluded_count -gt 0 ] && echo -e "\n${YELLOW}($excluded_count excluded share(s) omitted)${NC}"

    echo ""
    echo "────────────────────────────────────────────"
    echo ""
    echo -e "${BOLD}To install:${NC}"
    echo ""
    if [[ "$PROTOCOL" == "smb" ]]; then
        echo "  1. Create credentials file:"
        echo -e "     ${CYAN}sudo tee $cred_file <<EOF"
        echo "username=${NAS_USER:-your_username}"
        echo "password=${NAS_PASS:-your_password}"
        echo -e "EOF${NC}"
        echo -e "     ${CYAN}sudo chmod 600 $cred_file${NC}"
        echo ""
        echo "  2. Create mount points:"
    else
        echo "  1. Create mount points:"
    fi
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        is_excluded "$share" && continue
        echo -e "     ${CYAN}sudo mkdir -p $MOUNT_BASE/$share${NC}"
    done <<< "$share_list"
    echo ""
    echo "  3. Add the lines above to /etc/fstab"
    echo ""
    echo "  4. Mount with:"
    echo -e "     ${CYAN}sudo mount -a${NC}"
    echo ""
    echo -e "${YELLOW}Note: 'noauto,x-systemd.automount' means shares mount on-demand${NC}"
    echo -e "${YELLOW}      and disconnect after 60s idle — great for laptops.${NC}"
    echo -e "${YELLOW}      '_netdev' ensures boot doesn't hang without network.${NC}"
    echo -e "${YELLOW}      'x-systemd.mount-timeout=10' caps mount wait to 10s.${NC}"
    echo ""

    echo -n "Would you like to install these fstab entries now? (y/N): "
    read -r answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        # Filter out excluded shares before passing to install_fstab
        local filtered_list=""
        while IFS= read -r share; do
            share=$(echo "$share" | xargs)
            [ -z "$share" ] && continue
            is_excluded "$share" && continue
            filtered_list="${filtered_list}${share}"$'\n'
        done <<< "$share_list"
        filtered_list=$(echo "$filtered_list" | sed '/^$/d')
        install_fstab "$filtered_list" "$cred_file"
    fi
}

install_fstab() {
    local share_list="$1"
    local cred_file="$2"

    echo ""

    # ── Test mount each share before touching fstab ──────────────────────
    echo -e "${BOLD}Testing mount points before writing to fstab...${NC}"
    if ! check_nas; then
        echo -e "${RED}Cannot reach NAS at $NAS_IP — aborting fstab install${NC}"
        return 1
    fi

    local cred_opts
    cred_opts=$(build_cred_opts)
    local verified_shares=""
    local test_failed=0

    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        local test_mp
        test_mp=$(mktemp -d "/tmp/nas-test-mount.XXXXXX")

        echo -n "  Testing $(share_source "$NAS_IP" "$share") ... "

        local mount_type
        mount_type=$(fstab_fstype)
        local src
        src=$(share_source "$NAS_IP" "$share")
        local mount_output
        mount_output=$(sudo timeout "$TIMEOUT" mount -t "$mount_type" "$src" "$test_mp" -o "$cred_opts" 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}✓ OK${NC}"
            sudo umount "$test_mp" 2>/dev/null
            verified_shares="${verified_shares}${share}"$'\n'
        elif [ $exit_code -eq 124 ]; then
            echo -e "${RED}✗ timed out after ${TIMEOUT}s — skipping${NC}"
            ((test_failed++))
        elif echo "$mount_output" | grep -q "Permission denied\|error(13)"; then
            echo -e "${YELLOW}⊘ permission denied — skipping${NC}"
            ((test_failed++))
        else
            local reason
            reason=$(parse_mount_error "$mount_output")
            echo -e "${RED}✗ $reason — skipping${NC}"
            ((test_failed++))
        fi
        rmdir "$test_mp" 2>/dev/null
    done <<< "$share_list"

    cleanup_credentials

    # Strip trailing newline
    verified_shares=$(echo "$verified_shares" | sed '/^$/d')

    if [ -z "$verified_shares" ]; then
        echo -e "${RED}No shares passed the mount test — nothing added to fstab${NC}"
        return 1
    fi

    if [ $test_failed -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}$test_failed share(s) failed testing and will be skipped.${NC}"
        echo -n "Continue adding the verified shares to fstab? (y/N): "
        read -r cont
        if [[ ! "$cont" =~ ^[Yy] ]]; then
            echo "Aborted."
            return 1
        fi
    fi

    echo ""

    # ── Create credential file (SMB only) ────────────────────────────────
    if [[ "$PROTOCOL" == "smb" ]]; then
        echo -e "Creating credentials file at ${CYAN}$cred_file${NC}..."
        sudo tee "$cred_file" > /dev/null <<EOF
username=${NAS_USER:-guest}
password=${NAS_PASS:-}
EOF
        sudo chmod 600 "$cred_file"
        echo -e "${GREEN}✓ Credentials file created${NC}"
    fi

    # Create mount points (owned by the invoking user, not root)
    local mount_uid=${SUDO_UID:-$(id -u)}
    local mount_gid=${SUDO_GID:-$(id -g)}
    sudo mkdir -p "$MOUNT_BASE"
    sudo chown "$mount_uid:$mount_gid" "$MOUNT_BASE"
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        sudo mkdir -p "$MOUNT_BASE/$share"
        sudo chown "$mount_uid:$mount_gid" "$MOUNT_BASE/$share"
    done <<< "$verified_shares"
    echo -e "${GREEN}✓ Mount points created${NC}"

    # Backup fstab
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}✓ Backed up /etc/fstab${NC}"

    # Resolve the real user's UID/GID (works whether invoked directly or via sudo)
    local fstab_uid=${SUDO_UID:-$(id -u)}
    local fstab_gid=${SUDO_GID:-$(id -g)}

    # Add entries (skip if already present)
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        local mp="$MOUNT_BASE/$share"
        local src
        src=$(share_source "$NAS_IP" "$share")
        local fstype
        fstype=$(fstab_fstype)
        local entry
        local extra_opts="${MOUNT_OPTS:-nofail}"
        if [[ "$PROTOCOL" == "nfs" ]]; then
            local nfs_opts
            nfs_opts=$(build_nfs_fstab_opts)
            entry="$src  $mp  $fstype  $nfs_opts  0  0"
        else
            local smb_extra="${MOUNT_OPTS:-iocharset=utf8,file_mode=0775,dir_mode=0775,nofail}"
            entry="$src  $mp  $fstype  credentials=$cred_file,uid=$fstab_uid,gid=$fstab_gid,vers=$SMB_VERSION,actimeo=$CACHE_TIME,rsize=$RSIZE,wsize=$WSIZE,max_credits=$MAX_CREDITS,$smb_extra,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=10  0  0"
        fi

        if is_in_fstab "$NAS_IP" "$share"; then
            # Check if the existing entry points to a different mount base
            local existing_mp
            local check_pattern
            if [[ "$PROTOCOL" == "nfs" ]]; then
                check_pattern="$NAS_IP:/$share[[:space:]]"
            else
                check_pattern="//$NAS_IP/$share[[:space:]]"
            fi
            existing_mp=$(grep -E "^[^#].*$check_pattern" /etc/fstab 2>/dev/null | awk '{print $2}' | head -1)
            if [ -n "$existing_mp" ] && [ "$existing_mp" != "$mp" ]; then
                # Old entry with different mount point — stop old units, replace entry
                stop_old_units "$existing_mp"
                # Ensure new mount directory exists
                sudo mkdir -p "$mp"
                sudo chown "${mount_uid}:${mount_gid}" "$mp"
                # Replace the line in fstab
                local escaped_existing_mp
                escaped_existing_mp=$(printf '%s\n' "$existing_mp" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
                sudo sed -i "\\|$check_pattern|s|$escaped_existing_mp|$mp|" /etc/fstab
                echo -e "${GREEN}✓ Updated $share in fstab ($existing_mp → $mp)${NC}"
            else
                echo -e "${YELLOW}⊘ $share already in fstab — skipped${NC}"
            fi
        else
            echo "$entry" | sudo tee -a /etc/fstab >/dev/null
            echo -e "${GREEN}✓ Added $share to fstab${NC}"
        fi
    done <<< "$verified_shares"

    echo ""
    echo -e "${BOLD}Activating mounts...${NC}"
    sudo systemctl daemon-reload
    echo -e "${GREEN}✓ systemd reloaded${NC}"
    sudo mount -a 2>&1
    echo -e "${GREEN}✓ mount -a complete${NC}"

    # Start automount units (mount -a alone doesn't activate them)
    start_automount_units

    # Create convenience symlink (e.g. ~/nas → /mnt/nas)
    ensure_symlink

    # Update file manager bookmarks
    update_bookmarks

    echo ""
    echo -e "${GREEN}Done! Shares will auto-mount on access at $MOUNT_BASE/${NC}"
}

# ── Interactive Setup Wizard ─────────────────────────────────────────────────

interactive_setup() {
    echo -e "${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║       NAS Mount Manager — Setup        ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""

    # ── Step 1: NAS IP ───────────────────────────────────────────────────
    echo -e "${BOLD}Step 1: NAS Address${NC}"
    echo -n "  NAS IP address [$NAS_IP]: "
    read -r input_ip
    NAS_IP="${input_ip:-$NAS_IP}"
    echo ""

    # Quick check
    if ! check_nas; then
        echo ""
        echo -n "NAS is unreachable. Continue anyway? (y/N): "
        read -r cont
        if [[ ! "$cont" =~ ^[Yy] ]]; then
            echo "Aborted."
            return 1
        fi
    fi
    echo ""

    # ── Step 2: Protocol ─────────────────────────────────────────────────
    echo -e "${BOLD}Step 2: Protocol${NC}"
    echo "  1) SMB/CIFS — Windows/Samba shares (username + password)"
    echo "  2) NFS      — Linux/Unix exports (host-based auth, no password)"
    echo -n "  Choose [1]: "
    read -r proto_choice
    case "${proto_choice:-1}" in
        2|nfs|NFS)  PROTOCOL="nfs" ;;
        *)          PROTOCOL="smb" ;;
    esac
    echo -e "  → Protocol: ${CYAN}${PROTOCOL^^}${NC}"

    # Auto-detect best NFS version if NFS selected
    if [[ "$PROTOCOL" == "nfs" ]]; then
        echo -n "  Detecting NFS version support... "
        local detected_ver=""
        for try_ver in 4.2 4.1 4.0 3; do
            if timeout 5 rpcinfo -p "$NAS_IP" 2>/dev/null | grep -q "nfs"; then
                # Use rpcinfo to check major version support
                local major="${try_ver%%.*}"
                if timeout 5 rpcinfo -p "$NAS_IP" 2>/dev/null | grep -q "nfs.*$major"; then
                    # For minor version, try a quick test mount
                    local probe_dir
                    probe_dir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/.nfs-probe-XXXXXX")
                    if sudo timeout 5 mount -t nfs -o "vers=$try_ver,ro,noatime,timeo=30,retrans=1" "$NAS_IP":/ "$probe_dir" 2>/dev/null; then
                        sudo umount "$probe_dir" 2>/dev/null
                        rmdir "$probe_dir" 2>/dev/null
                        detected_ver="$try_ver"
                        break
                    fi
                    rmdir "$probe_dir" 2>/dev/null
                fi
            else
                break
            fi
        done
        if [ -n "$detected_ver" ]; then
            NFS_VERSION="$detected_ver"
            echo -e "${GREEN}NFSv$detected_ver${NC}"
        else
            echo -e "${YELLOW}could not detect (will use v$NFS_VERSION, with fallback)${NC}"
        fi
    fi
    echo ""

    # ── Step 3: Credentials (SMB only) ───────────────────────────────────
    if [[ "$PROTOCOL" == "smb" ]]; then
        echo -e "${BOLD}Step 3: Credentials${NC}"
        if [ -z "$NAS_USER" ]; then
            echo -n "  SMB username (Enter for guest): "
            read -r NAS_USER
        else
            echo -e "  Username: ${CYAN}$NAS_USER${NC} (from config/env)"
            echo -n "  Change username? (Enter to keep, or type new): "
            read -r new_user
            [ -n "$new_user" ] && NAS_USER="$new_user"
        fi

        if [ -n "$NAS_USER" ] && [ -z "$NAS_PASS" ]; then
            # Try keyring
            local keyring_pass
            keyring_pass=$(keyring_lookup "$NAS_IP" "$NAS_USER" 2>/dev/null)
            if [ -n "$keyring_pass" ]; then
                NAS_PASS="$keyring_pass"
                echo -e "  ${GREEN}✓ Password retrieved from keyring${NC}"
            else
                echo -n "  Password for $NAS_USER: "
                read -rs NAS_PASS
                echo ""
            fi
        fi
        echo ""
    else
        echo -e "${BOLD}Step 3: Credentials${NC}"
        echo -e "  ${CYAN}NFS uses host-based auth — no credentials needed.${NC}"
        echo ""
    fi

    # ── Step 4: Discover shares ──────────────────────────────────────────
    echo -e "${BOLD}Step 4: Discover Shares${NC}"
    echo ""
    local share_list=""
    if discover_shares; then
        share_list="$DISCOVERED_SHARES"
    else
        echo ""
        if [[ "$PROTOCOL" == "nfs" ]]; then
            echo -e "  Enter NFS export names (without leading /)."
            echo -e "  Example: ${CYAN}media,backups,documents${NC}"
            echo -e "  (Check your NAS admin panel for the exact export paths)"
        else
            echo -e "  Example: ${CYAN}media,backups,documents${NC}"
        fi
        echo -n "  Share names (comma-separated): "
        read -r manual_shares
        share_list=$(echo "$manual_shares" | tr ',' '\n')
    fi

    if [ -z "$share_list" ]; then
        echo -e "${RED}No shares found or entered. Aborting.${NC}"
        return 1
    fi

    # ── Step 5: Select shares ────────────────────────────────────────────
    echo -e "${BOLD}Step 5: Select Shares to Mount${NC}"
    echo ""

    # Number each share for selection
    local share_array=()
    local i=1
    while IFS= read -r s; do
        s=$(echo "$s" | xargs)
        [ -z "$s" ] && continue
        share_array+=("$s")
        echo -e "  ${CYAN}$i)${NC} $s"
        ((i++))
    done <<< "$share_list"
    echo -e "  ${CYAN}A)${NC} All of the above"
    echo ""

    echo -n "  Enter choices (e.g. 1,3,5 or A for all) [A]: "
    read -r selection

    local selected_shares=""
    if [[ -z "$selection" || "$selection" =~ ^[Aa] ]]; then
        selected_shares="$share_list"
        echo -e "  → Mounting ${GREEN}all${NC} shares"
    else
        IFS=',' read -ra picks <<< "$selection"
        for pick in "${picks[@]}"; do
            pick=$(echo "$pick" | xargs)
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#share_array[@]} ]; then
                local idx=$((pick - 1))
                if [ -n "$selected_shares" ]; then
                    selected_shares="$selected_shares"$'\n'"${share_array[$idx]}"
                else
                    selected_shares="${share_array[$idx]}"
                fi
            else
                echo -e "  ${YELLOW}Skipping invalid selection: $pick${NC}"
            fi
        done
        if [ -z "$selected_shares" ]; then
            echo -e "${RED}No valid shares selected. Aborting.${NC}"
            return 1
        fi
        echo -e "  → Selected: ${CYAN}$(echo "$selected_shares" | tr '\n' ',' | sed 's/,$//')${NC}"
    fi
    echo ""

    # ── Step 6: Mount path ───────────────────────────────────────────────
    echo -e "${BOLD}Step 6: Mount Location${NC}"
    echo -n "  Mount base path [$MOUNT_BASE]: "
    read -r input_mount
    MOUNT_BASE="${input_mount:-$MOUNT_BASE}"
    echo ""

    # ── Step 7: Confirm and mount ────────────────────────────────────────
    echo -e "${BOLD}Summary${NC}"
    echo "═══════════════════════════════════════"
    echo -e "  NAS IP:      ${CYAN}$NAS_IP${NC}"
    echo -e "  Protocol:    ${CYAN}${PROTOCOL^^}${NC}"
    if [[ "$PROTOCOL" == "smb" ]]; then
        echo -e "  Username:    ${CYAN}${NAS_USER:-guest}${NC}"
    fi
    echo -e "  Mount base:  ${CYAN}$MOUNT_BASE${NC}"
    echo -e "  Shares:      ${CYAN}$(echo "$selected_shares" | tr '\n' ',' | sed 's/,$//')${NC}"
    echo ""

    echo -n "Proceed with mounting? (Y/n): "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Aborted."
        return 0
    fi
    echo ""

    # Override SHARES so mount_all uses our selection
    SHARES=$(echo "$selected_shares" | tr '\n' ',' | sed 's/,$//')
    mount_all

    echo ""

    # ── Optional: Set up fstab entries ───────────────────────────────────
    echo ""
    echo -e "${BOLD}Fstab Integration (optional)${NC}"
    echo "  Adding fstab entries lets shares auto-mount when you access them,"
    echo "  auto-disconnect when idle, and gracefully handle being off-network."
    echo "  This is the recommended setup for laptops."
    echo ""
    echo -n "Set up fstab entries for these shares? (y/N): "
    read -r setup_fstab
    if [[ "$setup_fstab" =~ ^[Yy] ]]; then
        echo ""
        # Call the existing fstab generation with current settings
        # The shares and protocol are already set from the wizard
        generate_fstab
    fi

    # ── Optional: Save config ────────────────────────────────────────────
    echo ""
    echo -n "Save these settings to config file for next time? (y/N): "
    read -r save_config
    if [[ "$save_config" =~ ^[Yy] ]]; then
        # Write a simple config (re-use generate_config logic inline)
        local save_pass_to_config=true
        if [[ "$PROTOCOL" == "smb" ]] && has_keyring && [ -n "$NAS_USER" ] && [ -n "$NAS_PASS" ]; then
            echo ""
            echo "Password storage:"
            echo "  1) System keyring (encrypted)"
            echo "  2) Config file (plaintext, chmod 600)"
            echo -n "  Choose [1]: "
            read -r storage_choice
            if [[ "${storage_choice:-1}" == "1" ]]; then
                if keyring_store "$NAS_IP" "$NAS_USER" "$NAS_PASS"; then
                    echo -e "${GREEN}✓ Password saved to keyring${NC}"
                    save_pass_to_config=false
                fi
            fi
        fi

        if [[ "$PROTOCOL" == "nfs" ]]; then
            cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration — saved by setup wizard
# Generated on $(date)
PROTOCOL="$PROTOCOL"
NAS_IP="$NAS_IP"
MOUNT_BASE="$MOUNT_BASE"
NFS_VERSION="$NFS_VERSION"
SHARES="$SHARES"
CACHE_TIME="$CACHE_TIME"
RSIZE="$RSIZE"
WSIZE="$WSIZE"
NFS_NCONNECT="$NFS_NCONNECT"
NFS_TIMEO="$NFS_TIMEO"
NFS_RETRANS="$NFS_RETRANS"
EOF
        elif $save_pass_to_config; then
            cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration — saved by setup wizard
# Generated on $(date)
PROTOCOL="$PROTOCOL"
NAS_IP="$NAS_IP"
NAS_USER="$NAS_USER"
NAS_PASS="$NAS_PASS"
MOUNT_BASE="$MOUNT_BASE"
SMB_VERSION="$SMB_VERSION"
SHARES="$SHARES"
CACHE_TIME="$CACHE_TIME"
RSIZE="$RSIZE"
WSIZE="$WSIZE"
MAX_CREDITS="$MAX_CREDITS"
EOF
        else
            cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration — saved by setup wizard
# Generated on $(date)
# Password stored in system keyring
PROTOCOL="$PROTOCOL"
NAS_IP="$NAS_IP"
NAS_USER="$NAS_USER"
MOUNT_BASE="$MOUNT_BASE"
SMB_VERSION="$SMB_VERSION"
SHARES="$SHARES"
CACHE_TIME="$CACHE_TIME"
RSIZE="$RSIZE"
WSIZE="$WSIZE"
MAX_CREDITS="$MAX_CREDITS"
EOF
        fi
        chmod 600 "$CONFIG_FILE"
        echo -e "${GREEN}✓ Config saved to $CONFIG_FILE${NC}"
        echo -e "  Next time just run: ${CYAN}$(basename "$0") mount${NC}"
    fi
}

generate_config() {
    echo -e "${BOLD}NAS Config Generator${NC}"
    echo ""

    echo -n "NAS IP [$NAS_IP]: "
    read -r input_ip
    local cfg_ip="${input_ip:-$NAS_IP}"

    echo -n "Protocol (smb/nfs) [$PROTOCOL]: "
    read -r input_proto
    local cfg_proto="${input_proto:-$PROTOCOL}"
    case "$cfg_proto" in
        smb|nfs) ;;
        *) echo -e "${RED}Invalid protocol '$cfg_proto'. Must be 'smb' or 'nfs'.${NC}"; return 1 ;;
    esac

    local cfg_user="" cfg_pass=""
    if [[ "$cfg_proto" == "smb" ]]; then
        echo -n "NAS username (Enter for guest): "
        read -r cfg_user

        if [ -n "$cfg_user" ]; then
            echo -n "NAS password: "
            read -rs cfg_pass
            echo ""
        fi
    fi

    echo -n "Mount base path [$MOUNT_BASE]: "
    read -r input_mount
    local cfg_mount="${input_mount:-$MOUNT_BASE}"

    local cfg_smb="$SMB_VERSION"
    local cfg_nfs="$NFS_VERSION"
    if [[ "$cfg_proto" == "smb" ]]; then
        echo -n "SMB version [$SMB_VERSION]: "
        read -r input_smb
        cfg_smb="${input_smb:-$SMB_VERSION}"
    else
        echo -n "NFS version [$NFS_VERSION]: "
        read -r input_nfs
        cfg_nfs="${input_nfs:-$NFS_VERSION}"
    fi

    echo -n "Shares (comma-separated, or Enter to auto-discover): "
    read -r cfg_shares

    echo -n "Shares to exclude (comma-separated, or Enter for none): "
    read -r cfg_exclude

    echo -n "Cache timeout in seconds [$CACHE_TIME] (higher = faster on WiFi, lower = fresher): "
    read -r input_cache
    local cfg_cache="${input_cache:-$CACHE_TIME}"

    echo -n "Read buffer size in bytes [$RSIZE] (4194304 = 4MB, good for large files): "
    read -r input_rsize
    local cfg_rsize="${input_rsize:-$RSIZE}"

    echo -n "Write buffer size in bytes [$WSIZE] (4194304 = 4MB, good for large files): "
    read -r input_wsize
    local cfg_wsize="${input_wsize:-$WSIZE}"

    local cfg_credits="$MAX_CREDITS"
    local cfg_nconnect="$NFS_NCONNECT"
    local cfg_timeo="$NFS_TIMEO"
    local cfg_retrans="$NFS_RETRANS"
    if [[ "$cfg_proto" == "smb" ]]; then
        echo -n "SMB3 max credits [$MAX_CREDITS] (higher = more parallel requests): "
        read -r input_credits
        cfg_credits="${input_credits:-$MAX_CREDITS}"
    else
        echo -n "NFS nconnect [$NFS_NCONNECT] (0=disabled, 2-16 for multi-channel I/O): "
        read -r input_nconnect
        cfg_nconnect="${input_nconnect:-$NFS_NCONNECT}"

        echo -n "NFS timeo in deciseconds [$NFS_TIMEO] (150 = 15s initial timeout): "
        read -r input_timeo
        cfg_timeo="${input_timeo:-$NFS_TIMEO}"

        echo -n "NFS retrans [$NFS_RETRANS] (retransmission count before failure): "
        read -r input_retrans
        cfg_retrans="${input_retrans:-$NFS_RETRANS}"
    fi

    # Decide where to store the password (SMB only)
    local save_pass_to_config=true
    if [[ "$cfg_proto" == "smb" ]] && has_keyring && [ -n "$cfg_user" ] && [ -n "$cfg_pass" ]; then
        echo ""
        echo "Password storage options:"
        echo "  1) System keyring (recommended — encrypted, no plaintext on disk)"
        echo "  2) Config file (plaintext, chmod 600)"
        echo -n "Choose [1]: "
        read -r storage_choice
        if [[ "${storage_choice:-1}" == "1" ]]; then
            if keyring_store "$cfg_ip" "$cfg_user" "$cfg_pass"; then
                echo -e "${GREEN}✓ Password saved to system keyring${NC}"
                save_pass_to_config=false
            else
                echo -e "${YELLOW}⚠ Keyring save failed — falling back to config file${NC}"
            fi
        fi
    fi

    if [[ "$cfg_proto" == "nfs" ]]; then
        cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration
# Generated on $(date)

PROTOCOL="$cfg_proto"
NAS_IP="$cfg_ip"
MOUNT_BASE="$cfg_mount"
NFS_VERSION="$cfg_nfs"
SHARES="$cfg_shares"
EXCLUDE_SHARES="$cfg_exclude"
CACHE_TIME="$cfg_cache"
RSIZE="$cfg_rsize"
WSIZE="$cfg_wsize"
NFS_NCONNECT="$cfg_nconnect"
NFS_TIMEO="$cfg_timeo"
NFS_RETRANS="$cfg_retrans"

# Additional mount options (comma-separated)
# MOUNT_OPTS="nofail"
EOF
    elif $save_pass_to_config; then
        cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration
# Generated on $(date)

PROTOCOL="$cfg_proto"
NAS_IP="$cfg_ip"
NAS_USER="$cfg_user"
NAS_PASS="$cfg_pass"
MOUNT_BASE="$cfg_mount"
SMB_VERSION="$cfg_smb"
SHARES="$cfg_shares"
EXCLUDE_SHARES="$cfg_exclude"
CACHE_TIME="$cfg_cache"
RSIZE="$cfg_rsize"
WSIZE="$cfg_wsize"
MAX_CREDITS="$cfg_credits"

# Additional mount options (comma-separated)
# MOUNT_OPTS="iocharset=utf8,file_mode=0775,dir_mode=0775,nofail"
EOF
    else
        cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration
# Generated on $(date)
# Password is stored in the system keyring (secret-tool)

PROTOCOL="$cfg_proto"
NAS_IP="$cfg_ip"
NAS_USER="$cfg_user"
MOUNT_BASE="$cfg_mount"
SMB_VERSION="$cfg_smb"
SHARES="$cfg_shares"
EXCLUDE_SHARES="$cfg_exclude"
CACHE_TIME="$cfg_cache"
RSIZE="$cfg_rsize"
WSIZE="$cfg_wsize"
MAX_CREDITS="$cfg_credits"

# Additional mount options (comma-separated)
# MOUNT_OPTS="iocharset=utf8,file_mode=0775,dir_mode=0775,nofail"
EOF
    fi

    echo ""
    echo -e "${GREEN}✓ Config saved to $CONFIG_FILE${NC}"
    if [[ "$cfg_proto" == "smb" ]] && $save_pass_to_config && [ -n "$cfg_pass" ]; then
        echo -e "${YELLOW}Note: Config file contains your password in plain text.${NC}"
        echo -e "${YELLOW}      Consider: sudo apt install libsecret-tools${NC}"
        echo -e "${YELLOW}      Then re-run 'config' to use the system keyring instead.${NC}"
    fi
    chmod 600 "$CONFIG_FILE"
}

# Validate that a value is a positive integer
validate_positive_int() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -eq 0 ]; then
        echo -e "${RED}Error: $name must be a positive integer (got '$value')${NC}" >&2
        exit 1
    fi
}

# ── Parse CLI arguments ──────────────────────────────────────────────────────

# Collect ALL args first so flags can appear before or after the command
COMMAND=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--ip)        NAS_IP="$2";       shift 2 ;;
        --protocol)     PROTOCOL="$2";     shift 2 ;;
        -u|--user)      NAS_USER="$2";     shift 2 ;;
        -p|--pass)      NAS_PASS="$2";     shift 2 ;;
        -m|--mount)     MOUNT_BASE="$2";   shift 2 ;;
        --symlink)      SYMLINK_PATH="$2";  shift 2 ;;
        --no-symlink)   NO_SYMLINK=true;    shift ;;
        -s|--shares)    SHARES="$2";       shift 2 ;;
        -e|--exclude)   EXCLUDE_SHARES="$2"; shift 2 ;;
        --smb-version)  SMB_VERSION="$2";  shift 2 ;;
        --nfs-version)  NFS_VERSION="$2";  shift 2 ;;
        --nfs-nconnect) NFS_NCONNECT="$2";  shift 2 ;;
        --nfs-timeo)    NFS_TIMEO="$2";    shift 2 ;;
        --nfs-retrans)  NFS_RETRANS="$2";  shift 2 ;;
        --timeout|-t)   TIMEOUT="$2";      shift 2 ;;
        --cache-time)   CACHE_TIME="$2";     shift 2 ;;
        --rsize)        RSIZE="$2";          shift 2 ;;
        --wsize)        WSIZE="$2";          shift 2 ;;
        --max-credits)  MAX_CREDITS="$2";    shift 2 ;;
        --dry-run)      DRY_RUN=true;      shift ;;
        --no-color)     GREEN='' RED='' YELLOW='' CYAN='' BOLD='' NC=''; shift ;;
        --version)      echo "NAS Mount Manager v$VERSION"; exit 0 ;;
        --config)       CONFIG_FILE="$2"; source "$CONFIG_FILE" 2>/dev/null; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
        *)              POSITIONAL+=("$1"); shift ;;
    esac
done

# First positional arg is the command
COMMAND="${POSITIONAL[0]:-}"

# Validate inputs
validate_protocol
validate_positive_int "--timeout"     "$TIMEOUT"
validate_positive_int "--cache-time"  "$CACHE_TIME"
validate_positive_int "--rsize"       "$RSIZE"
validate_positive_int "--wsize"       "$WSIZE"
validate_positive_int "--max-credits" "$MAX_CREDITS"

case "${COMMAND:-}" in
    mount|m)          mount_all ;;
    remount|r)        remount_all ;;
    unmount|umount|u) unmount_all ;;
    repair|x)         repair_all ;;
    status|s)         show_status ;;
    discover|d)       discover_shares ;;
    fstab|f)          generate_fstab ;;
    fstab-manage|fm)  fstab_manage ;;
    fstab-remove|fr)  fstab_remove ;;
    fstab-edit|fe)    fstab_edit ;;
    setup|wizard|w)   interactive_setup ;;
    migrate)          migrate_mounts "$HOME/nas" ;;
    config|c)         generate_config ;;
    *)                usage ;;
esac
