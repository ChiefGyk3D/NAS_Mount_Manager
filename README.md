# NAS Mount Manager

On-demand mounting/unmounting of SMB/CIFS NAS shares — ideal for laptops.

## Quick Start

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

## Commands

| Command    | Short | Description                                    |
|------------|-------|------------------------------------------------|
| `mount`    | `m`   | Mount NAS shares (skips fstab-managed ones)    |
| `unmount`  | `u`   | Unmount all NAS shares (cleans empty dirs)     |
| `status`   | `s`   | Show mount status, disk usage, and fstab info  |
| `discover` | `d`   | List available SMB shares with descriptions    |
| `fstab`    | `f`   | Generate and optionally install fstab entries   |
| `config`   | `c`   | Interactive config file generator               |
| `help`     | `h`   | Show help                                       |

## CLI Options

```
-i, --ip IP         NAS IP address (default: 192.168.1.10)
-u, --user USER     SMB username
-p, --pass PASS     SMB password
-m, --mount PATH    Mount base path (default: ~/nas)
-s, --shares LIST   Comma-separated share names
-t, --timeout SEC   Connection timeout in seconds (default: 30)
--smb-version VER   SMB protocol version for mount (default: 3.0)
--dry-run           Show what would be done without doing it
--no-color          Disable colored output
--config FILE       Path to config file
--version           Show version
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

```bash
# nas.conf
NAS_IP="192.168.1.10"
NAS_USER="myuser"
NAS_PASS="mypassword"
MOUNT_BASE="/home/user/nas"
SMB_VERSION="3.0"
SHARES="media,backups,documents"
TIMEOUT=30
```

The config file is automatically set to `chmod 600` and ignored by `.gitignore`.

## Fstab Integration

### Generating Fstab Entries

```bash
./mount-nas.sh fstab
```

This generates laptop-friendly entries with `noauto,x-systemd.automount,x-systemd.idle-timeout=60`.
Shares auto-mount when you `cd` into them and auto-disconnect after 60 seconds of inactivity.

The tool will:
- Show the generated fstab lines
- Offer to install them automatically
- Back up `/etc/fstab` before any changes
- Create a secure credentials file at `/etc/nas-credentials` (chmod 600)
- **Skip shares already in fstab** to prevent duplicates

### Fstab-Aware Mounting

When you run `./mount-nas.sh mount`, shares that are already managed by fstab are
**automatically skipped** with a helpful message pointing you to use `cd` or `sudo mount`
for those shares instead. This prevents conflicts between manual mounts and systemd automounts.

### Fstab Status

`./mount-nas.sh status` shows both active mounts and existing fstab entries for your NAS,
so you can see at a glance what's managed where.

## Dry Run

Preview what would happen without actually mounting anything:

```bash
./mount-nas.sh --dry-run -u myuser mount
```

## Environment Variables

| Variable          | Description                          | Default             |
|-------------------|--------------------------------------|---------------------|
| `NAS_IP`          | NAS IP address                       | `192.168.1.10`      |
| `NAS_USER`        | SMB username                         | *(prompt)*          |
| `NAS_PASS`        | SMB password                         | *(prompt)*          |
| `NAS_MOUNT_BASE`  | Mount base path                      | `~/nas`             |
| `NAS_SHARES`      | Comma-separated share list           | *(auto-discover)*   |
| `NAS_SMB_VERSION`  | SMB protocol version                | `3.0`               |
| `NAS_MOUNT_OPTS`  | Additional mount options             | `iocharset=utf8,...` |
| `NAS_TIMEOUT`     | Connection timeout (seconds)         | `30`                |
| `NAS_CONFIG`      | Path to config file                  | `./nas.conf`        |
| `NO_COLOR`        | Disable colored output (`true`)      | `false`             |

## Shell Alias

Add to `~/.bashrc` or `~/.zshrc`:

```bash
alias nas='~/src/NAS_mount/mount-nas.sh'
```

Then use from anywhere:

```bash
nas mount          # Mount all shares
nas status         # Check what's connected
nas unmount        # Disconnect everything
nas -i 10.0.0.5 d  # Discover shares on a different NAS
```

## Requirements

```bash
# Required
sudo apt install cifs-utils smbclient

# Optional (for secure password storage in system keyring)
sudo apt install libsecret-tools
```

## Password Security

The script supports multiple levels of credential security:

### System Keyring (Recommended)

If `libsecret-tools` is installed, the script integrates with your system keyring
(GNOME Keyring / KDE Wallet). Passwords are encrypted and managed by your desktop
environment:

```bash
# Install keyring support
sudo apt install libsecret-tools

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
- Passwords are **never passed on the command line** to `mount` or `smbclient` — temporary credential files are used instead, so passwords don't appear in `/proc` or `ps` output
- Temp credential files are created with `chmod 600` and **securely deleted** (`shred`) after use
- Config files are excluded from git via `.gitignore`
- The `-p` flag is available for scripting but not recommended for interactive use

## License

MIT
