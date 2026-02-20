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
MOUNT_BASE="${NAS_MOUNT_BASE:-$HOME/nas}"
NAS_USER="${NAS_USER:-}"
NAS_PASS="${NAS_PASS:-}"
SHARES="${NAS_SHARES:-}"
SMB_VERSION="${NAS_SMB_VERSION:-3.0}"
MOUNT_OPTS="${NAS_MOUNT_OPTS:-iocharset=utf8,file_mode=0775,dir_mode=0775,nofail}"
TIMEOUT=${NAS_TIMEOUT:-30}
EXCLUDE_SHARES="${NAS_EXCLUDE_SHARES:-}"

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

VERSION="1.3.0"
DISCOVERED_SHARES=""
DRY_RUN=false
NO_COLOR=${NO_COLOR:-false}

# Disable colors if requested or not a terminal
if [[ "$NO_COLOR" == "true" ]] || [[ ! -t 1 ]]; then
    GREEN='' RED='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# ── Fstab Helpers ────────────────────────────────────────────────────────────

# Get all fstab entries for a given NAS IP
get_fstab_entries() {
    local ip="$1"
    grep -v '^#' /etc/fstab 2>/dev/null | grep "//$ip/" || true
}

# Check if a specific share is already in fstab
is_in_fstab() {
    local ip="$1" share="$2"
    grep -q "//$ip/$share" /etc/fstab 2>/dev/null
}

# Show fstab status for current NAS
show_fstab_status() {
    local entries
    entries=$(get_fstab_entries "$NAS_IP")
    if [ -n "$entries" ]; then
        echo -e "  ${BOLD}Fstab entries for $NAS_IP:${NC}"
        while IFS= read -r line; do
            local share
            share=$(echo "$line" | awk '{print $1}' | sed "s|//$NAS_IP/||")
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
    echo "  status,   s       Show current mount status"
    echo "  discover, d       Discover available SMB shares"
    echo "  fstab,    f       Generate /etc/fstab entries"
    echo "  config,   c       Generate a config file interactively"
    echo "  help,     h       Show this help"
    echo ""
    echo "Options:"
    echo "  -i, --ip IP       NAS IP address (default: $NAS_IP)"
    echo "  -u, --user USER   SMB username"
    echo "  -p, --pass PASS   SMB password"
    echo "  -m, --mount PATH  Mount base path (default: $MOUNT_BASE)"
    echo "  -s, --shares LIST Comma-separated share names"
    echo "  -e, --exclude LIST Comma-separated shares to skip (e.g. homes,photo)"
    echo "  -t, --timeout SEC Connection timeout in seconds (default: $TIMEOUT)"
    echo "  --smb-version VER SMB protocol version (default: $SMB_VERSION)"
    echo "  --dry-run         Show what would be done without doing it"
    echo "  --no-color        Disable colored output"
    echo "  --config FILE     Path to config file"
    echo "  --version         Show version"
    echo ""
    echo "Environment Variables:"
    echo "  NAS_IP, NAS_USER, NAS_PASS, NAS_MOUNT_BASE, NAS_SHARES,"
    echo "  NAS_SMB_VERSION, NAS_MOUNT_OPTS, NAS_CONFIG, NAS_TIMEOUT,"
    echo "  NAS_EXCLUDE_SHARES, NO_COLOR"
    echo ""
    echo "Config File: $CONFIG_FILE"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") mount                           # Mount with defaults/config"
    echo "  $(basename "$0") -i 10.0.0.5 discover            # Discover shares on different NAS"
    echo "  $(basename "$0") -i 10.0.0.5 -u admin mount      # Mount with specific IP and user"
    echo "  $(basename "$0") -s media,backups mount           # Mount specific shares only"
    echo "  $(basename "$0") -e homes,photo mount             # Mount all except excluded shares"
    echo "  $(basename "$0") fstab                            # Generate fstab entries"
}

check_deps() {
    local missing=()
    for cmd in mount umount; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v mount.cifs &>/dev/null && ! [ -f /sbin/mount.cifs ]; then
        missing+=("cifs-utils")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing required packages: ${missing[*]}${NC}"
        echo "Install with: sudo apt install cifs-utils smbclient"
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
    secret-tool lookup service nas-mount-test key ping 2>/dev/null
    # lookup returns 1 when key not found (which is fine — service is reachable)
    # but returns other codes or hangs when service is unavailable
    return 0
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
    local tmpfile
    tmpfile=$(mktemp /tmp/.nas-creds-XXXXXX)
    chmod 600 "$tmpfile"
    cat > "$tmpfile" <<CREDEOF
username=${NAS_USER}
password=${NAS_PASS}
CREDEOF
    echo "$tmpfile"
}

build_cred_opts() {
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
    opts="$opts,uid=$mount_uid,gid=$mount_gid,vers=$SMB_VERSION,$MOUNT_OPTS"
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

    if ! command -v smbclient &>/dev/null; then
        echo -e "${YELLOW}smbclient not installed. Install with: sudo apt install smbclient${NC}"
        return 1
    fi

    get_credentials

    echo "Discovering shares on $NAS_IP..."
    local output
    if [ -n "$NAS_USER" ]; then
        # Use authentication file for smbclient to avoid password in process list
        local smb_auth
        smb_auth=$(mktemp /tmp/.nas-smb-auth-XXXXXX)
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
    share_list=$(echo "$output" | grep -i "Disk" | awk '{print $1}' | grep -v '^\$' | grep -v 'IPC')

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
        done <<< "$(echo "$output" | grep -i 'Disk' | grep -v 'IPC')"
        echo ""
        DISCOVERED_SHARES="$share_list"
        return 0
    else
        echo -e "${RED}No shares found. Raw output:${NC}"
        echo "$output" | head -20
        return 1
    fi
}

mount_all() {
    check_deps || return 1
    if ! check_nas; then
        echo -e "${RED}Cannot mount — NAS is not reachable${NC}"
        return 1
    fi

    get_credentials

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
            fstab_mp=$(echo "$fstab_entries" | grep "//$NAS_IP/$share \|//$NAS_IP/$share\t" | awk '{print $2}' | head -1)
            echo -e "  ${YELLOW}⊘ $share — managed by fstab (mount point: ${fstab_mp:-$mp})${NC}"
            echo -e "    ${CYAN}Use 'sudo mount $fstab_mp' or just 'cd $fstab_mp' if using automount${NC}"
            ((skipped++))
            continue
        fi

        if $DRY_RUN; then
            echo -e "  ${CYAN}[dry-run]${NC} Would mount //$NAS_IP/$share → $mp"
            ((mounted++))
            continue
        fi

        mkdir -p "$mp"

        echo -n "  Mounting //$NAS_IP/$share → $mp ... "

        if mount | grep -q " $mp "; then
            echo -e "${YELLOW}already mounted${NC}"
            ((mounted++))
            continue
        fi

        local mount_output
        mount_output=$(sudo timeout "$TIMEOUT" mount -t cifs "//$NAS_IP/$share" "$mp" -o "$cred_opts" 2>&1)
        local exit_code=$?

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

        if mount | grep -q " ${mp%/} "; then
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
        if ! mount | grep -q " ${mp%/} " && [ -z "$(ls -A "${mp%/}" 2>/dev/null)" ]; then
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
    for mp in "$MOUNT_BASE"/*/; do
        [ ! -d "$mp" ] && continue
        local name
        name=$(basename "$mp")
        if mount | grep -q " ${mp%/} "; then
            local size
            size=$(df -h "${mp%/}" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 " used)"}')
            echo -e "    ${GREEN}● $name${NC}  $size"
            ((mounted++))
        else
            echo -e "    ${RED}○ $name${NC}  (not mounted)"
        fi
    done

    [ $mounted -eq 0 ] && echo "    No shares currently mounted"
}

generate_fstab() {
    get_credentials

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

    echo ""
    echo -e "${BOLD}Generated /etc/fstab entries:${NC}"
    echo "────────────────────────────────────────────"
    echo ""

    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        local mp="$MOUNT_BASE/$share"
        echo "//$NAS_IP/$share  $mp  cifs  credentials=$cred_file,vers=$SMB_VERSION,$MOUNT_OPTS,noauto,x-systemd.automount,x-systemd.idle-timeout=60  0  0"
    done <<< "$share_list"

    echo ""
    echo "────────────────────────────────────────────"
    echo ""
    echo -e "${BOLD}To install:${NC}"
    echo ""
    echo "  1. Create credentials file:"
    echo -e "     ${CYAN}sudo tee $cred_file <<EOF"
    echo "username=${NAS_USER:-your_username}"
    echo "password=${NAS_PASS:-your_password}"
    echo -e "EOF${NC}"
    echo -e "     ${CYAN}sudo chmod 600 $cred_file${NC}"
    echo ""
    echo "  2. Create mount points:"
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
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
    echo ""

    echo -n "Would you like to install these fstab entries now? (y/N): "
    read -r answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        install_fstab "$share_list" "$cred_file"
    fi
}

install_fstab() {
    local share_list="$1"
    local cred_file="$2"

    echo ""
    # Create credential file
    echo -e "Creating credentials file at ${CYAN}$cred_file${NC}..."
    sudo bash -c "cat > $cred_file" <<EOF
username=${NAS_USER:-guest}
password=${NAS_PASS:-}
EOF
    sudo chmod 600 "$cred_file"
    echo -e "${GREEN}✓ Credentials file created${NC}"

    # Create mount points
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        sudo mkdir -p "$MOUNT_BASE/$share"
    done <<< "$share_list"
    echo -e "${GREEN}✓ Mount points created${NC}"

    # Backup fstab
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}✓ Backed up /etc/fstab${NC}"

    # Add entries (skip if already present)
    while IFS= read -r share; do
        share=$(echo "$share" | xargs)
        [ -z "$share" ] && continue
        local mp="$MOUNT_BASE/$share"
        local entry="//$NAS_IP/$share  $mp  cifs  credentials=$cred_file,vers=$SMB_VERSION,$MOUNT_OPTS,noauto,x-systemd.automount,x-systemd.idle-timeout=60  0  0"

        if grep -q "//$NAS_IP/$share" /etc/fstab 2>/dev/null; then
            echo -e "${YELLOW}⊘ $share already in fstab — skipped${NC}"
        else
            echo "$entry" | sudo tee -a /etc/fstab >/dev/null
            echo -e "${GREEN}✓ Added $share to fstab${NC}"
        fi
    done <<< "$share_list"

    echo ""
    echo -e "${GREEN}Done! Reload systemd and mount with:${NC}"
    echo -e "  ${CYAN}sudo systemctl daemon-reload${NC}"
    echo -e "  ${CYAN}sudo mount -a${NC}"
}

generate_config() {
    echo -e "${BOLD}NAS Config Generator${NC}"
    echo ""

    echo -n "NAS IP [$NAS_IP]: "
    read -r input_ip
    local cfg_ip="${input_ip:-$NAS_IP}"

    echo -n "NAS username (Enter for guest): "
    read -r cfg_user

    local cfg_pass=""
    if [ -n "$cfg_user" ]; then
        echo -n "NAS password: "
        read -rs cfg_pass
        echo ""
    fi

    echo -n "Mount base path [$MOUNT_BASE]: "
    read -r input_mount
    local cfg_mount="${input_mount:-$MOUNT_BASE}"

    echo -n "SMB version [$SMB_VERSION]: "
    read -r input_smb
    local cfg_smb="${input_smb:-$SMB_VERSION}"

    echo -n "Shares (comma-separated, or Enter to auto-discover): "
    read -r cfg_shares

    echo -n "Shares to exclude (comma-separated, or Enter for none): "
    read -r cfg_exclude

    # Decide where to store the password
    local save_pass_to_config=true
    if has_keyring && [ -n "$cfg_user" ] && [ -n "$cfg_pass" ]; then
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

    if $save_pass_to_config; then
        cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration
# Generated on $(date)

NAS_IP="$cfg_ip"
NAS_USER="$cfg_user"
NAS_PASS="$cfg_pass"
MOUNT_BASE="$cfg_mount"
SMB_VERSION="$cfg_smb"
SHARES="$cfg_shares"
EXCLUDE_SHARES="$cfg_exclude"

# Additional mount options (comma-separated)
# MOUNT_OPTS="iocharset=utf8,file_mode=0775,dir_mode=0775,nofail"
EOF
    else
        cat > "$CONFIG_FILE" <<EOF
# NAS Mount Configuration
# Generated on $(date)
# Password is stored in the system keyring (secret-tool)

NAS_IP="$cfg_ip"
NAS_USER="$cfg_user"
MOUNT_BASE="$cfg_mount"
SMB_VERSION="$cfg_smb"
SHARES="$cfg_shares"
EXCLUDE_SHARES="$cfg_exclude"

# Additional mount options (comma-separated)
# MOUNT_OPTS="iocharset=utf8,file_mode=0775,dir_mode=0775,nofail"
EOF
    fi

    echo ""
    echo -e "${GREEN}✓ Config saved to $CONFIG_FILE${NC}"
    if $save_pass_to_config && [ -n "$cfg_pass" ]; then
        echo -e "${YELLOW}Note: Config file contains your password in plain text.${NC}"
        echo -e "${YELLOW}      Consider: sudo apt install libsecret-tools${NC}"
        echo -e "${YELLOW}      Then re-run 'config' to use the system keyring instead.${NC}"
    fi
    chmod 600 "$CONFIG_FILE"
}

# ── Parse CLI arguments ──────────────────────────────────────────────────────

# Collect ALL args first so flags can appear before or after the command
COMMAND=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--ip)        NAS_IP="$2";       shift 2 ;;
        -u|--user)      NAS_USER="$2";     shift 2 ;;
        -p|--pass)      NAS_PASS="$2";     shift 2 ;;
        -m|--mount)     MOUNT_BASE="$2";   shift 2 ;;
        -s|--shares)    SHARES="$2";       shift 2 ;;
        -e|--exclude)   EXCLUDE_SHARES="$2"; shift 2 ;;
        --smb-version)  SMB_VERSION="$2";  shift 2 ;;
        --timeout|-t)   TIMEOUT="$2";      shift 2 ;;
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

case "${COMMAND:-}" in
    mount|m)          mount_all ;;
    remount|r)        remount_all ;;
    unmount|umount|u) unmount_all ;;
    status|s)         show_status ;;
    discover|d)       discover_shares ;;
    fstab|f)          generate_fstab ;;
    config|c)         generate_config ;;
    *)                usage ;;
esac
