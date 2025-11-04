# CryptoShred

**Securely encrypt and destroy data with a random key**

CryptoShred is a collection of scripts designed to securely and permanently destroy data on storage devices by encrypting them with randomly generated one-time keys. Once encrypted, the data becomes cryptographically irretrievable without the key, which is never stored.

## 🚨 **WARNING** 🚨

**This tool will PERMANENTLY DESTROY ALL DATA on the target device!**
- All data on the target drive will become completely inaccessible
- There is NO way to recover the data once the process completes
- Make absolutely sure you select the correct device
- Ensure all important data is backed up before use

## Overview

The CryptoShred project consists of three main components:

1. **`CryptoShred.sh`** - The core encryption script
2. **`BuildCryptoShred.sh`** - Creates a bootable Debian-based ISO with CryptoShred pre-installed
3. **`CleanupBuildEnvironment.sh`** - Cleans up build artifacts and environments

## Features

- **Hardware & Software Encryption Support**: Supports both Opal hardware encryption (SED drives) and LUKS2 software encryption
- **Automatic Boot Device Protection**: Prevents accidental destruction of the system's boot device
- **Live Environment Optimized**: Designed to work reliably in USB live environments
- **Zero Key Storage**: Encryption keys are never written to disk or stored anywhere
- **Bootable ISO Creation**: Build custom Debian ISOs with CryptoShred pre-installed
- **Clean Environment Execution**: Runs in a clean environment to avoid conflicts

## System Requirements

### For CryptoShred.sh:
- Linux operating system (Debian-based recommended)
- `bash` shell
- `cryptsetup` (for LUKS2 encryption)
- `lsblk` and `findmnt` utilities
- `sedutil-cli` (optional, for Opal SED drive support)
- Root privileges (`sudo`)

### For BuildCryptoShred.sh:
- Debian-based Linux system
- `bash` shell
- Root privileges (`sudo`)
- Internet connection for downloading components
- Required tools: `cryptsetup`, `7z`, `unsquashfs`, `xorriso`, `wget`, `curl`
- Approximately 4-8 GB of free disk space
- USB device for writing the ISO

## Installation

### Quick Start (Run from GitHub)

The simplest way to use CryptoShred is to run it directly from GitHub:

```bash
# Download and run CryptoShred directly
wget -O- https://raw.githubusercontent.com/PostWarTacos/CryptoShred/main/CryptoShred.sh | sudo bash

# Download BuildCryptoShred.sh and run with required execution method
wget https://raw.githubusercontent.com/PostWarTacos/CryptoShred/main/BuildCryptoShred.sh -O ~/BuildCryptoShred.sh
chmod +x ~/BuildCryptoShred.sh
sudo -i bash -lc 'exec 3>/tmp/build-trace.log; export BASH_XTRACEFD=3; export PS4="+ $(date +%H:%M:%S) ${BASH_SOURCE}:${LINENO}: "; DEBUG=1 '$HOME'/BuildCryptoShred.sh'
```

### Local Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/PostWarTacos/CryptoShred.git
   cd CryptoShred
   ```

2. **Make scripts executable:**
   ```bash
   chmod +x *.sh
   ```

3. **Install dependencies (if not already installed):**
   ```bash
   sudo apt update
   sudo apt install cryptsetup p7zip-full squashfs-tools xorriso wget curl
   ```

## Usage

### CryptoShred.sh - Core Encryption Script

The main script that performs the data destruction:

```bash
sudo ./CryptoShred.sh
```

**What it does:**
1. Detects and protects the boot device from accidental selection
2. Lists available storage devices
3. Prompts for device selection with safety confirmations
4. Checks for Opal SED support (uses software LUKS2 by preference)
5. Creates LUKS2 encryption with a random 512-bit key
6. Immediately discards the key, making data permanently inaccessible

**Interactive Process:**
- Lists all available drives (excluding the boot device)
- Requires typing "YES" in capitals to confirm
- Shows detailed progress during encryption
- Provides clear success/failure messages

### BuildCryptoShred.sh - Bootable ISO Builder

Creates a bootable Debian-based ISO with CryptoShred pre-installed.

**⚠️ REQUIRED EXECUTION METHOD:**
```bash
sudo -i bash -lc 'exec 3>/tmp/build-trace.log; export BASH_XTRACEFD=3; export PS4="+ $(date +%H:%M:%S) ${BASH_SOURCE}:${LINENO}: "; DEBUG=1 /home/username/Documents/CryptoShred/BuildCryptoShred.sh'
```
Replace `username` with your actual username and adjust the path as needed.

**DO NOT** simply run `sudo ./BuildCryptoShred.sh` - the script requires the specific execution method shown above.

This execution method:
- Creates a detailed trace log at `/tmp/build-trace.log` for troubleshooting
- Sets up the proper environment variables required by the script
- Ensures compatibility with the script's internal error handling and debugging systems
- Automatically tracks and reports build times and timestamps

**DO NOT use relative paths** - always use the full absolute path to the script.

**Features:**
- **Branch Selection**: Choose from main (stable), develop (latest), or custom branches
- **Version Checking**: Built-in update checking against GitHub
- **Automatic Setup**: Downloads latest Debian live ISO and integrates CryptoShred
- **Multiple USB Support**: Can write to multiple USB devices sequentially
- **Auto-boot Configuration**: CryptoShred starts automatically on first boot

**Build Process:**
1. Prompts for branch selection (main/develop/custom)
2. Downloads and validates CryptoShred scripts from GitHub
3. Downloads latest Debian live ISO
4. Modifies the ISO to include CryptoShred and dependencies
5. Creates systemd service for auto-start
6. Builds new ISO and writes to USB device

**Command Line Options:**
```bash
# Check version against a specific branch
sudo -i bash -lc 'exec 3>/tmp/build-trace.log; export BASH_XTRACEFD=3; export PS4="+ $(date +%H:%M:%S) ${BASH_SOURCE}:${LINENO}: "; DEBUG=1 /path/to/BuildCryptoShred.sh --version-check [branch]'

# Show help (can be run without the special execution method)
./BuildCryptoShred.sh --help
```

### CleanupBuildEnvironment.sh - Environment Cleanup

Cleans up build artifacts and mounted filesystems:

```bash
sudo ./CleanupBuildEnvironment.sh
```

**What it cleans:**
- Unmounts all chroot filesystems (dev, proc, sys, tmp, etc.)
- Terminates processes using build directories
- Detaches loop devices
- Removes build directories and temporary files
- Performs system cache cleanup

**Use cases:**
- After a failed or interrupted build
- Before running a new build to ensure clean environment
- When build directories are consuming disk space

## Technical Details

### Encryption Specifications

**LUKS2 Software Encryption:**
- **Cipher**: AES-XTS-Plain64
- **Key Size**: 512 bits (64 bytes)
- **PBKDF**: Argon2id
- **Memory Cost**: 4 GB per password guess
- **Time Cost**: 5 seconds minimum per guess
- **Parallelism**: 4 threads

**Security Features:**
- Random key generation using `/dev/urandom`
- Key piped directly to cryptsetup (never written to disk)
- No key storage or recovery mechanism
- Strong PBKDF parameters make brute force attacks impractical

### Opal SED Support

CryptoShred can detect Opal Self-Encrypting Drives (SEDs) but currently defaults to software LUKS2 encryption for consistency. The script includes infrastructure for Opal support via `sedutil-cli`.

### Boot Device Protection

The script automatically detects the boot device using:
1. `findmnt` to identify the root filesystem source
2. `lsblk` to determine the parent disk
3. Overlay filesystem detection for live environments
4. Excludes the boot device from the selection list

## Error Handling

### Common Issues and Solutions

**"Device already contains signature" errors:**
- Run CleanupBuildEnvironment.sh first
- Ensure no swap partitions are in use
- Check that target device is not mounted

**Build fails with mount errors:**
- Previous build may have left mounted filesystems
- Run CleanupBuildEnvironment.sh to clean up
- Reboot if cleanup script cannot resolve issues

**Permission denied errors:**
- Ensure running with sudo/root privileges
- Check file system permissions
- Verify target device is not in use

**Network timeouts during build:**
- Check internet connection
- Retry the build process
- Use local Debian mirror if available

## Security Considerations

### Data Destruction Assurance

**What CryptoShred does:**
- Creates strong encryption that makes data computationally infeasible to recover
- Uses cryptographically secure random number generation
- Employs industry-standard encryption algorithms (AES-256-XTS)
- Implements strong key derivation functions (Argon2id)

**What CryptoShred does NOT do:**
- Does not overwrite data multiple times (unnecessary with modern SSDs)
- Does not guarantee compliance with specific regulatory standards
- Does not protect against physical attacks on the encryption hardware
- Does not prevent data recovery from damaged/partial sectors (though recovery would be meaningless without the key)

### Threat Model

CryptoShred is designed to protect against:
- Data recovery by unauthorized parties
- Forensic analysis of discarded drives
- Data breaches from lost or stolen devices
- Accidental data exposure

CryptoShred may not protect against:
- Nation-state actors with quantum computing capabilities (theoretical future threat)
- Physical attacks on encryption hardware/firmware
- Side-channel attacks on the encryption process
- Data that was already copied elsewhere

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is released under the MIT License. See the repository for full license details.

## Disclaimer

**USE AT YOUR OWN RISK**

This software is provided "as is" without warranty of any kind. The authors and contributors are not responsible for any data loss, hardware damage, or other consequences of using this software. Always verify your target device selection and ensure you have proper backups before proceeding.

## Support

- **Issues**: Report bugs and request features on GitHub Issues
- **Documentation**: Check this README and in-script comments
- **Community**: Discussions on GitHub Discussions page

---

**Remember: Data destruction is permanent. Triple-check your device selection before confirming!**