# NAS Mount Manager

On-demand mounting/unmounting of SMB/CIFS and NFS NAS shares — ideal for laptops.

Supports both **SMB** (Windows/Samba shares) and **NFS** (Linux/Unix exports) via the `--protocol` flag.

## Quick Start

### Interactive Setup (easiest)

```bash
# Install dependencies for your protocol of choice
sudo apt install cifs-utils smbclient   # SMB
sudo apt install nfs-common             # NFS

# Run the guided wizard — walks you through everything
chmod +x mount-nas.sh
./mount-nas.sh setup
```

The wizard guides you through: NAS IP → protocol → credentials → share discovery → selection → mounting, and optionally saves your config for next time.

### SMB (default)

```bash
# Install dependencies
sudo apt install cifs-utils smbclient

# Make executable
chmod +x mount-nas.sh

# Discover what shares are available
./mount-nas.sh -u myuser discover

# Mount all shares
./mount-nas.sh -u myuser mount

# Check status (shows disk usage + fstab entries)
./mount-nas.sh status

# Unmount when done
./mount-nas.sh unmount

# Save your settings so you don't have to repeat flags
./mount-nas.sh config
```

### NFS

```bash
# Install dependencies
sudo apt install nfs-common

# Discover available NFS exports
./mount-nas.sh --protocol nfs discover

# Mount all NFS exports
./mount-nas.sh --protocol nfs mount

# Mount specific exports
./mount-nas.sh --protocol nfs -s media,backups mount

# Repair stale/broken NFS mounts (resets systemd automount units)
./mount-nas.sh --protocol nfs repair

# Generate fstab entries for NFS
./mount-nas.sh --protocol nfs fstab

# Save NFS settings to config
./mount-nas.sh --protocol nfs config
```

## Commands

| Command    | Short | Description                                     |
|------------|-------|-------------------------------------------------|
| `mount`    | `m`   | Mount NAS shares (skips fstab-managed ones)     |
| `remount`  | `r`   | Unmount and re-mount all NAS shares             |
| `unmount`  | `u`   | Unmount all NAS shares (cleans empty dirs)      |
| `repair`   | `x`   | Detect and fix stale/broken mounts (automount-aware) |
| `status`   | `s`   | Show mount status, disk usage, and fstab info   |
| `discover` | `d`   | List available shares (SMB) or exports (NFS)    |
| `fstab`    | `f`   | Generate and optionally install fstab entries    |
| `fstab-manage` | `fm` | Interactive fstab manager (list/add/remove/edit) |
| `fstab-remove` | `fr` | Remove fstab entries for NAS shares            |
| `fstab-edit`   | `fe` | Edit mount options on an existing fstab entry  |
| `migrate`    |       | Migrate mounts from ~/nas to /mnt/nas (Flatpak fix) |
| `config`   | `c`   | Interactive config file generator                |
| `setup`    | `w`   | Interactive guided setup wizard                  |
| `help`     | `h`   | Show help                                        |

## CLI Options

```
-i, --ip IP           NAS IP address (default: 192.168.1.10)
--protocol TYPE       Protocol: smb or nfs (default: smb)
-u, --user USER       SMB username
-p, --pass PASS       SMB password
-m, --mount PATH      Mount base path (default: /mnt/nas)
--symlink PATH        Convenience symlink path (default: ~/nas)
--no-symlink          Don't create ~/nas symlink
-s, --shares LIST     Comma-separated share names
-e, --exclude LIST    Comma-separated shares to skip (e.g. homes,photo)
-t, --timeout SEC     Connection timeout in seconds (default: 30)
--cache-time SEC      Attribute cache timeout in seconds (default: 10)
--rsize BYTES         Read buffer size in bytes (default: 4194304 / 4MB)
--wsize BYTES         Write buffer size in bytes (default: 4194304 / 4MB)
--max-credits N       SMB3 max credits / request parallelism (default: 128)
--smb-version VER     SMB protocol version for mount (default: 3.0)
--nfs-version VER     NFS protocol version for mount (default: 4)
--nfs-nconnect N      NFS multi-connection count, 0=disabled (default: 0)
--nfs-timeo DS        NFS timeout in deciseconds (default: 150 = 15s)
--nfs-retrans N       NFS retransmission count (default: 3)
--dry-run             Show what would be done without doing it
--no-color            Disable colored output
--config FILE         Path to config file
--version             Show version
```

Flags can appear **before or after** the command:

```bash
# Both work the same
./mount-nas.sh -u admin mount
./mount-nas.sh mount -u admin
```

## Configuring the NAS IP

The default IP is `192.168.1.10`. Override it in any of these ways:

```bash
# CLI flag (one-time)
./mount-nas.sh -i 10.0.0.5 mount

# Environment variable (one-time)
NAS_IP=10.0.0.5 ./mount-nas.sh mount

# Config file (persistent)
./mount-nas.sh config
```

## Config File

Run `./mount-nas.sh config` to generate `nas.conf` interactively, or create one manually:

### SMB Config Example

```bash
# nas.conf
PROTOCOL="smb"
NAS_IP="192.168.1.10"
NAS_USER="myuser"
NAS_PASS="mypassword"
MOUNT_BASE="/mnt/nas"
SMB_VERSION="3.0"
SHARES="media,backups,documents"
EXCLUDE_SHARES="homes,photo"
CACHE_TIME=10
RSIZE=4194304
WSIZE=4194304
MAX_CREDITS=128
TIMEOUT=30
```

### NFS Config Example

```bash
# nas.conf
PROTOCOL="nfs"
NAS_IP="192.168.1.10"
MOUNT_BASE="/mnt/nas"
NFS_VERSION="4"
SHARES="media,backups,documents"
EXCLUDE_SHARES=""
CACHE_TIME=10
RSIZE=4194304
WSIZE=4194304
NFS_NCONNECT=0
NFS_TIMEO=150
NFS_RETRANS=3
TIMEOUT=30
```

The config file is automatically set to `chmod 600` and ignored by `.gitignore`.

## Fstab Integration

### Why Fstab? (Especially for Laptops)

Fstab entries let systemd manage your NAS shares with **on-demand mounting** — which is
ideal for laptops that roam between networks. The generated entries include:

| Option | Purpose |
|--------|---------|
| `noauto` | Don't mount at boot — avoids boot hangs when not on your home network |
| `x-systemd.automount` | Mount on first access (e.g. `cd ~/nas/media`) |
| `x-systemd.idle-timeout=60` | Auto-unmount after 60s idle — saves resources on battery |
| `x-systemd.mount-timeout=10` | Give up after 10s if NAS unreachable — prevents long freezes |
| `_netdev` | Tells systemd this needs network — skips gracefully with no network |
| `nofail` | Boot continues normally even if the mount fails |
| `soft` (NFS only) | Returns errors instead of hanging forever if NAS disappears mid-transfer |

**What happens on a laptop with these entries:**
- **At home on your network**: `cd ~/nas/media` mounts instantly, unmounts when idle
- **Away from home (coffee shop, travel)**: Accessing the path returns a quick error after 10s instead of freezing your terminal or file manager
- **No network at all**: Boot is unaffected, no hangs, no delays
- **NAS goes offline while mounted**: NFS `soft` returns an I/O error instead of hanging processes; SMB times out cleanly

### Setting Up Fstab

The easiest way is through the **setup wizard**, which offers fstab at the end:

```bash
./mount-nas.sh setup
# ... walks through protocol, credentials, discovery, mounting ...
# Then asks: "Set up fstab entries for these shares? (y/N)"
```

Or generate them directly:

```bash
./mount-nas.sh fstab
```

Generated entries include `uid=` and `gid=` so mounted files are **owned by your user**, not root.
The `actimeo` value (set via `--cache-time`) is baked into each entry for consistent caching.
The `--exclude` / `-e` flag is respected — excluded shares are omitted from generated entries.

The tool will:
- **Test-mount each share** before touching fstab (skips any that fail)
- Show the generated fstab lines
- Offer to install them automatically
- Back up `/etc/fstab` before any changes
- Create a secure credentials file at `/etc/nas-credentials` (chmod 600)
- Create mount directories **owned by your user** (not root)
- **Auto-run** `systemctl daemon-reload` and `mount -a`
- **Skip shares already in fstab** to prevent duplicates

### Managing Fstab Entries

Use the interactive fstab manager to list, add, remove, or edit entries:

```bash
./mount-nas.sh fstab-manage          # Interactive menu
./mount-nas.sh fstab-remove          # Remove entries (select by number or 'all')
./mount-nas.sh fstab-edit            # Edit mount point or options on an entry
```

The manager works with entries created by this tool **or added manually** — it finds
all `/etc/fstab` lines matching your NAS IP. Removals and edits always **back up fstab
first** (`/etc/fstab.bak.<timestamp>`), reload systemd, and optionally unmount removed shares.

### Fstab-Aware Mounting

When you run `./mount-nas.sh mount`, shares that are already managed by fstab are
**automatically skipped** with a helpful message pointing you to use `cd` or `sudo mount`.

### Fstab Status

`./mount-nas.sh status` shows both active mounts and existing fstab entries for your NAS,
so you can see at a glance what's managed where.

### Repairing Stale Mounts

NFS mounts (especially on laptops) can go **stale** when the NAS becomes temporarily
unreachable — e.g. after sleep/wake, network changes, or VPN toggling. A stale mount
appears in `mount` output but hangs when you try to access it. The `repair` command
fixes this automatically:

```bash
./mount-nas.sh repair                     # Repair all fstab-managed shares
./mount-nas.sh --protocol nfs repair      # Explicitly specify NFS
```

**What `repair` does for each fstab-managed share:**

1. **Pings the NAS** to confirm it's reachable
2. **Health-checks each mount** — attempts `stat` with a 3-second timeout
3. If stale or unresponsive:
   - **Lazy-unmounts** the dead kernel mount (`umount -l`)
   - **Stops and resets** the systemd automount/mount units (`reset-failed`)
   - **Restarts** the automount unit so on-demand mounting works again
   - **Verifies access** by listing the share contents
4. Reports a summary: OK / repaired / failed

**When to use `repair` vs `remount`:**

| Situation | Use |
|-----------|-----|
| One or two shares went stale, others are fine | `repair` — only touches broken ones |
| All shares need a clean restart | `remount` — tears down and re-mounts everything |
| Shares hang after sleep/wake or VPN toggle | `repair` — designed for exactly this |
| Changed mount options in fstab | `remount` — picks up new options |

> **Tip:** Avoid running `sudo umount -l` manually on automounted shares — it breaks the
> systemd automount pipe and leaves the unit in a `failed` state. Use `repair` instead.

## Dry Run

Preview what would happen without actually mounting anything:

```bash
./mount-nas.sh --dry-run -u myuser mount
```

## Flatpak Compatibility

When NAS shares are mounted under `/home` (the old default `~/nas`), **Flatpak apps
fail to launch** with errors like:

```
bwrap: Can't bind mount /oldroot/home on /newroot/home: Unable to remount recursively with correct flags: No such device
error: Failed to sync with dbus proxy
```

This happens because Flatpak's sandbox (bubblewrap) tries to recursively bind-mount
`/home`, which fails on `autofs` mount points created by `x-systemd.automount`.

**The fix:** Mount NAS shares outside `/home`. As of v2.1.0, the default `MOUNT_BASE`
is `/mnt/nas` instead of `~/nas`. A convenience symlink `~/nas → /mnt/nas` is
automatically created so your workflow stays the same.

### Migrating Existing Installs

If you set up NAS mounts with an older version (using `~/nas`), run the migration
command to move them to `/mnt/nas`:

```bash
./mount-nas.sh migrate
```

This will:
1. Stop existing automount units
2. Update `/etc/fstab` entries to use `/mnt/nas`
3. Create new mount directories
4. Create a `~/nas → /mnt/nas` symlink
5. Reload systemd and activate the new mounts
6. Update file manager bookmarks across all supported desktop environments

All fstab entries are backed up before modification.

### File Manager Bookmark Support

When mounts are installed or migrated, NAS Mount Manager automatically adds
sidebar bookmarks for every NAS share in your file manager. Supported formats:

| Desktop / File Manager | Bookmark File | Format |
|------------------------|---------------|--------|
| GNOME (Nautilus), Xfce (Thunar), Cinnamon (Nemo), COSMIC Files, Caja, PCManFM | `~/.config/gtk-3.0/bookmarks` | Text |
| GNOME 42+ (Nautilus on GTK4) | `~/.config/gtk-4.0/bookmarks` | Text |
| KDE (Dolphin), Qt file dialogs | `~/.local/share/user-places.xbel` | XBEL/XML |

All detected bookmark files are updated simultaneously. Old NAS bookmarks
(from previous mount paths) are automatically replaced with the current paths.

## Environment Variables

| Variable             | Description                          | Default             |
|----------------------|--------------------------------------|---------------------|
| `NAS_IP`             | NAS IP address                       | `192.168.1.10`      |
| `NAS_PROTOCOL`       | Protocol: `smb` or `nfs`             | `smb`               |
| `NAS_USER`           | SMB username                         | *(prompt)*          |
| `NAS_PASS`           | SMB password                         | *(prompt)*          |
| `NAS_MOUNT_BASE`     | Mount base path                      | `/mnt/nas`          |
| `NAS_SYMLINK`        | Convenience symlink path             | `~/nas`             |
| `NAS_SHARES`         | Comma-separated share list           | *(auto-discover)*   |
| `NAS_SMB_VERSION`    | SMB protocol version                 | `3.0`               |
| `NAS_NFS_VERSION`    | NFS protocol version                 | `4`                  |
| `NAS_MOUNT_OPTS`     | Additional mount options             | *(protocol default)*|
| `NAS_EXCLUDE_SHARES` | Comma-separated shares to skip       | *(none)*            |
| `NAS_CACHE_TIME`     | Attribute cache timeout (seconds)    | `10`                |
| `NAS_RSIZE`          | Read buffer size (bytes)             | `4194304` (4MB)     |
| `NAS_WSIZE`          | Write buffer size (bytes)            | `4194304` (4MB)     |
| `NAS_MAX_CREDITS`    | SMB3 max credits (parallelism)       | `128`               |
| `NAS_NFS_NCONNECT`   | NFS multi-connection count           | `0` (disabled)      |
| `NAS_NFS_TIMEO`      | NFS timeout (deciseconds)            | `150` (15s)         |
| `NAS_NFS_RETRANS`    | NFS retransmission count             | `3`                 |
| `NAS_TIMEOUT`        | Connection timeout (seconds)         | `30`                |
| `NAS_CONFIG`         | Path to config file                  | `./nas.conf`        |
| `NO_COLOR`           | Disable colored output (`true`)      | `false`             |

## Shell Alias

Add to `~/.bashrc` or `~/.zshrc`:

```bash
alias nas='~/src/NAS_Mount_Manager/mount-nas.sh'
```

Then use from anywhere:

```bash
nas mount                      # Mount all shares (SMB default)
nas --protocol nfs mount       # Mount NFS exports
nas remount                    # Unmount and re-mount (e.g. to fix permissions)
nas repair                     # Fix stale/broken mounts without full remount
nas status                     # Check what's connected
nas unmount                    # Disconnect everything
nas -i 10.0.0.5 d              # Discover SMB shares on a different NAS
nas --protocol nfs d            # Discover NFS exports
```

## Requirements

```bash
# For SMB/CIFS shares
sudo apt install cifs-utils smbclient

# For NFS exports
sudo apt install nfs-common

# Optional (for secure password storage in system keyring — SMB only)
sudo apt install libsecret-tools
```

## SMB vs NFS

| Feature | SMB (default) | NFS |
|---------|--------------|-----|
| **Best for** | Windows/macOS/mixed networks | Linux-to-Linux |
| **Authentication** | Username/password | Host-based (IP/subnet) or Kerberos |
| **Discovery** | `smbclient -L` | `showmount -e` |
| **Dependencies** | `cifs-utils`, `smbclient` | `nfs-common` |
| **File ownership** | Mapped via `uid=/gid=` mount options | Server-side UID/GID (must match) |
| **Performance** | Good with tuned buffers | Generally faster on Linux |
| **Credential files** | Yes (`/etc/nas-credentials`) | Not needed |

**When to use SMB:** Your NAS runs Windows/Samba, you have mixed OS clients, or you need per-user authentication.

**When to use NFS:** All clients are Linux, you want simpler setup, or you need the best raw throughput.

### NFS-Specific Notes

- NFS uses **host-based authentication** — the NAS controls access by client IP address or subnet, not username/password. The `-u`/`-p` flags are ignored for NFS.
- File ownership in NFS relies on matching UIDs/GIDs between client and server. Ensure your user IDs match or use NFSv4 ID mapping.
- NFS share names correspond to export paths on the server (e.g., `/volume1/media` becomes `volume1/media`).
- The `--max-credits` option is SMB-specific and is ignored for NFS mounts.

#### NFS Share Discovery

The script discovers NFS exports using two methods (automatic fallback):

1. **`showmount -e`** — queries the RPC portmapper (port 111). Fast and shows allowed hosts, but requires port 111 to be open. Many NAS firewalls block this.
2. **NFSv4 pseudo-root** — mounts `NAS_IP:/` read-only and lists top-level directories. Works even when portmapper is blocked (only needs port 2049). Requires `sudo`.

If both methods fail, you'll see troubleshooting tips and can enter share names manually.

**Common NFS discovery issues:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `clnt_create: RPC: Unable to receive` | Port 111 blocked | Normal — the script auto-falls back to NFSv4 pseudo-root |
| `mount: access denied` on pseudo-root | NAS doesn't allow your IP | Add this host's IP to the NFS allowed list on your NAS |
| Pseudo-root mounts but shows 0 exports | NAS doesn't export a browsable root | Enter share names manually (check NAS admin panel) |
| `showmount: command not found` | `nfs-common` not installed | `sudo apt install nfs-common` |

**NAS-specific NFS setup:**
- **Synology**: Control Panel → Shared Folder → Edit → NFS Permissions → Add your client IP
- **TrueNAS**: Sharing → Unix Shares (NFS) → Add dataset paths
- **QNAP**: Control Panel → Shared Folders → Edit → NFS host access
- **OpenMediaVault**: Services → NFS → Shares

## Password Security

The script supports multiple levels of credential security:

### System Keyring (Recommended)

If `libsecret-tools` is installed, the script integrates with your system keyring
(GNOME Keyring / KDE Wallet). Passwords are encrypted and managed by your desktop
environment:

```bash
# Install keyring support
sudo apt install libsecret-tools

# The keyring requires a D-Bus session bus (available in desktop sessions).
# If you're using SSH or a TTY without a desktop, start one first:
#   eval $(dbus-launch --sh-syntax)
#   gnome-keyring-daemon --start --components=secrets

# The script will automatically:
# 1. Check the keyring when a password is needed
# 2. Offer to save new passwords to the keyring
# 3. Use the keyring when generating config (no plaintext password in config file)

# You can also store via the config wizard:
./mount-nas.sh config   # Choose option 1 for keyring storage
```

### How Passwords Are Protected

| Method | Storage | Visible in `/proc`? | Persists? |
|--------|---------|---------------------|-----------|
| Interactive prompt | Memory only | No (temp file) | No |
| System keyring | Encrypted by OS | No (temp file) | Yes |
| Config file | `nas.conf` (chmod 600) | No (temp file) | Yes |
| Fstab credentials | `/etc/nas-credentials` (root, 600) | No | Yes |
| `-p` flag | Shell history | ⚠️ Yes (briefly) | No |

**Key security features:**
- Mounted shares are **owned by your user** (not root) — the script automatically passes `uid=` and `gid=` to `mount.cifs`, both for interactive mounts and fstab entries
- Passwords are **never passed on the command line** to `mount` or `smbclient` — temporary credential files are used instead, so passwords don't appear in `/proc` or `ps` output
- Temp credential files are stored in `$XDG_RUNTIME_DIR` (`/run/user/$UID`, a user-private tmpfs), created with `chmod 600`, and **securely deleted** (`shred`) after use
- Config files are excluded from git via `.gitignore`
- The `-p` flag is available for scripting but not recommended for interactive use

## Performance Tuning

All tuning options can be set via CLI flags, environment variables, or the config file.
Options marked **(SMB)** or **(NFS)** only apply to that protocol; others apply to both.

### Buffer Sizes — `rsize` / `wsize` (SMB + NFS)

Control the maximum read/write payload per network round-trip. The default is **4MB**
(4194304 bytes), which dramatically reduces round-trip overhead — especially over WiFi.

| Protocol | Kernel Default | Script Default | Effect |
|----------|---------------|----------------|--------|
| SMB/CIFS | 1MB | 4MB | Fewer round-trips per large file |
| NFS | 1MB (v3) / negotiated (v4) | 4MB | Same — server may cap lower |

```bash
# Defaults are already optimized for large transfers
./mount-nas.sh mount

# Explicitly set buffer sizes (both protocols)
./mount-nas.sh --rsize 4194304 --wsize 4194304 mount

# Smaller buffers for low-memory NAS or slow links
./mount-nas.sh --rsize 1048576 --wsize 1048576 mount
```

> **Tip:** The NFS server's `rsize`/`wsize` export settings can cap these values.
> Check your NAS export config if you're not seeing expected throughput.

### Attribute Caching — `actimeo` (SMB + NFS)

Controls how long the kernel caches file/directory metadata (size, timestamps, permissions)
before re-checking with the NAS. Higher = better performance, lower = fresher metadata.

```bash
# Lower value = fresher metadata, more network chatter
./mount-nas.sh --cache-time 1 mount

# Higher value = better performance, slightly stale metadata
./mount-nas.sh --cache-time 30 mount
```

| Value | Best For |
|-------|----------|
| `1`   | Multi-user editing where freshness matters |
| `10`  | General use, WiFi connections **(default)** |
| `30`  | Read-heavy workloads, media streaming |
| `60`  | Archival / backup shares you rarely write to |

### SMB3 Parallelism — `max_credits` (SMB only)

Controls how many simultaneous SMB3 requests the client can issue. The default is
**128** (kernel default is 64). Higher values allow more parallel I/O operations,
improving throughput for large file transfers and multi-file operations.

```bash
./mount-nas.sh --max-credits 128 mount

# Aggressive parallelism for high-bandwidth links
./mount-nas.sh --max-credits 256 mount
```

### SMB Protocol Version — `smb-version` (SMB only)

Controls the minimum SMB dialect. The default is **3.0**, which supports encryption,
multi-channel, and larger buffers.

| Version | Notes |
|---------|-------|
| `2.1`   | Minimum for `max_credits`; needed for very old NAS firmware |
| `3.0`   | **Default.** Encryption, better performance |
| `3.1.1` | Latest; pre-auth integrity, best security |

```bash
./mount-nas.sh --smb-version 3.1.1 mount
```

### NFS Multi-Connection — `nconnect` (NFS only)

Opens multiple TCP connections to the NFS server, distributing I/O across them.
This is a **major throughput boost** on fast networks (1GbE+), especially for
concurrent reads/writes or large sequential transfers.

Requires **NFSv4.1+** and **Linux kernel 5.3+**. Set to `0` (default) to disable.

```bash
# Use 4 parallel TCP connections (recommended starting point)
./mount-nas.sh --protocol nfs --nfs-nconnect 4 mount

# Aggressive: 8 connections for 10GbE+ links
./mount-nas.sh --protocol nfs --nfs-nconnect 8 mount
```

| Value | Best For |
|-------|----------|
| `0`   | Disabled **(default)** — single connection |
| `2-4` | Gigabit Ethernet, general improvement |
| `4-8` | 2.5GbE / 10GbE links |
| `8-16`| 10GbE+ with heavy concurrent workloads |

> **Note:** Not all NFS servers support `nconnect` well. If you see connection
> errors or degraded performance, reduce the value or set to `0`.

### NFS Timeout & Retransmission — `timeo` / `retrans` (NFS only)

Fine-tune how long the NFS client waits before retransmitting and how many
retries it attempts before reporting a failure.

- **`timeo`** — initial timeout in **deciseconds** (1/10 second). Default: `150` (15 seconds).
- **`retrans`** — number of retransmissions. Default: `3`.

```bash
# Faster failure detection on reliable LANs
./mount-nas.sh --protocol nfs --nfs-timeo 50 --nfs-retrans 2 mount

# More patience on flaky WiFi
./mount-nas.sh --protocol nfs --nfs-timeo 300 --nfs-retrans 5 mount
```

The script uses **`hard`** mounts by default, meaning NFS operations will retry
indefinitely after exhausting `retrans` attempts (the kernel keeps trying in the
background). This prevents data corruption but means a downed NAS can cause
processes to hang until it comes back. If you prefer timeout errors instead,
add `soft` to `MOUNT_OPTS`:

```bash
# Soft mount — operations fail after retries are exhausted
MOUNT_OPTS="soft,nofail" ./mount-nas.sh --protocol nfs mount
```

| Mount Type | Behavior | Best For |
|-----------|----------|----------|
| `hard` **(default)** | Retries forever | Data integrity, reliable networks |
| `soft` | Returns error after `retrans` | Laptops on flaky WiFi where hangs are worse than errors |

### NFS Protocol Version — `nfs-version` (NFS only)

| Version | Notes |
|---------|-------|
| `4`     | **Default.** Auto-negotiates the highest supported NFSv4 minor version |
| `4.2`   | Server-side copy, sparse files, best performance |
| `4.1`   | Session trunking, `nconnect` support |
| `4.0`   | Stateful, improved security, compound operations |
| `3`     | Stateless, widely compatible, no `nconnect` support |

The default `4` tells the kernel to negotiate the highest NFSv4 minor version the
server supports. If mounting fails with "Protocol not supported", the script
automatically falls back through `4.2 → 4.1 → 4.0 → 3` until one works.

The `setup` wizard also auto-detects the best version during its protocol step.

```bash
# Use NFSv3 for old NAS devices
./mount-nas.sh --protocol nfs --nfs-version 3 mount
```

### Protocol-Specific Tuning Summary

| Option | SMB | NFS | Default | Flag |
|--------|-----|-----|---------|------|
| Read buffer | Yes | Yes | 4MB | `--rsize` |
| Write buffer | Yes | Yes | 4MB | `--wsize` |
| Metadata caching | Yes | Yes | 10s | `--cache-time` |
| Max credits | Yes | — | 128 | `--max-credits` |
| Multi-connection | — | Yes | 0 (off) | `--nfs-nconnect` |
| Timeout | — | Yes | 150 (15s) | `--nfs-timeo` |
| Retransmissions | — | Yes | 3 | `--nfs-retrans` |
| Protocol version | Yes | Yes | 3.0 / 4 (auto) | `--smb-version` / `--nfs-version` |

### Downloading Large Files (ISOs, etc.)

For large downloads like ISOs, download directly on the NAS via SSH to bypass
your WiFi link entirely. The NAS is typically wired to your router at gigabit
speed, so downloads go **internet → router → NAS** instead of through your WiFi:

```bash
# One-liner: download directly on the NAS
ssh user@nas-ip 'wget -P /volume1/share/ "https://example.com/file.iso"'
```

### Network Recommendations

- **Ethernet** is always preferred for NAS access — consistent latency and full throughput
- **5 GHz WiFi** is a good alternative if Ethernet isn't available
- **2.4 GHz WiFi** works but may cause noticeable lag on directory listings; the default buffer sizes and cache settings help compensate
- For **NFS over WiFi**, increase `--nfs-timeo` and `--cache-time` to reduce sensitivity to latency spikes
- For **SMB over WiFi**, the default `rsize`/`wsize` of 4MB and `max_credits=128` are already tuned to compensate

### Benchmarking

Quick way to test throughput after tuning:

```bash
# Write test — create a 1GB file on the mounted share
dd if=/dev/zero of=~/nas/sharename/testfile bs=1M count=1024 oflag=direct 2>&1 | tail -1

# Read test — read it back
dd if=~/nas/sharename/testfile of=/dev/null bs=1M iflag=direct 2>&1 | tail -1

# Clean up
rm ~/nas/sharename/testfile
```

Compare results across different `rsize`/`wsize`, `nconnect`, and `max_credits` values
to find the optimal settings for your network and NAS hardware.

## License

Mozilla Public License Version 2.0 (MPL 2.0)

This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
