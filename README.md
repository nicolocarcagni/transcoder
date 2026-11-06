# Video Transcoder

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Language-Bash%204%2B-green.svg)](https://www.gnu.org/software/bash/)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-6%2B%20Recommended-red.svg)](https://ffmpeg.org/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-lightgrey.svg)](https://www.kernel.org/)

A production-grade shell script to normalize smartphone and camera recordings (Variable Frame Rate, HDR HLG, Dolby Vision) into rock-solid, editing-friendly intermediate formats (**Apple ProRes 422 LT** or **H.264 All-Intra**).

Optimized for video editors such as **Kdenlive**, **DaVinci Resolve**, **Adobe Premiere Pro**, and **Final Cut Pro**, solving timeline stuttering, audio desync, and washed-out HDR highlights.

---

## Table of Contents

- [Why Video Transcoder?](#why-video-transcoder)
- [Key Features](#key-features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [Interactive Mode](#interactive-mode)
  - [Command-Line Options](#command-line-options)
  - [Examples](#examples)
- [Technical Details](#technical-details)
  - [Video Codecs](#video-codecs)
  - [Color Space & HDR Tone Mapping](#color-space--hdr-tone-mapping)
  - [Disk Space Safety Pre-flight](#disk-space-safety-pre-flight)
  - [Safe Partial Writes & Signal Traps](#safe-partial-writes--signal-traps)
- [Contributing](#contributing)
- [License](#license)

---

## Why Video Transcoder?

Modern mobile devices (such as iPhones and Android flagships) record video using:
1. **Variable Frame Rate (VFR)**: Saves bandwidth by varying the frame rate depending on scene motion and lighting. This causes audio/video drift and timeline lag in non-linear editors (NLEs).
2. **HDR (HLG / Dolby Vision / BT.2020)**: Looks blown-out, overexposed, or flat/gray when imported directly into standard Rec.709 timelines without proper color transforms.
3. **Long-GOP Inter-frame Compression (HEVC/H.265)**: Highly compressed across groups of pictures, requiring intensive CPU/GPU decoding when scrubbing backwards and forwards on the editing timeline.

**Video Transcoder** automatically solves these issues by:
- Normalizing timestamps into a strict **Constant Frame Rate (CFR)**.
- Intelligently detecting HDR metadata and applying **high-quality tone mapping to standard Rec.709**.
- Converting compressed footage into **intra-frame editing codecs** where every frame is independently decoded.

---

## Key Features

- **Editing-Ready Codecs**:
  - **Apple ProRes 422 LT** (`prores_ks` profile 1, 10-bit 4:2:2): Broadcast standard, buttery-smooth scrubbing, pristine quality.
  - **H.264 All-Intra** (`libx264` fast, CRF 18, `g=1`, 8-bit 4:2:0): Lighter storage footprint while retaining full intra-frame random access.
- **CFR Framerate Normalization**: Choose between `30` or `60` fps constant frame rate.
- **Smart HDR Tone Mapping**: Automatically inspects color metadata (`arib-std-b67`, `smpte2084`, `bt2020`) and uses FFmpeg's `zscale` and Hable tone mapping algorithm (`tonemap=hable`) to map HDR highlights smoothly into BT.709.
- **Pre-flight Disk Space Safety Verification**: Calculates estimated output size dynamically according to duration, resolution, and target framerate, requiring an extra **+20% safety margin** to prevent filling up the disk mid-process.
- **Batch & Recursive Scanning**: Process an individual file, a single directory, or recursively scan nested directories (`-R`) while mirroring directory structures in the destination.
- **Safe Atomic Writes**: Transcodes into hidden partial files (`.filename.part.mov`). If canceled (`Ctrl+C` / `SIGINT` / `SIGTERM`) or if an error occurs, incomplete files are immediately purged, leaving zero corrupted files behind.
- **In-Place Overwrite Mode**: Replace original files one-by-one safely (`-w`, `--overwrite`). Encodes to an atomic hidden partial file and commits only when FFmpeg completes successfully with zero corruptions or damage if interrupted.
- **High-Fidelity Audio**: Normalizes audio tracks to uncompressed 16-bit 48 kHz stereo PCM (`pcm_s16le`).
- **Interactive & CLI Interface**: Run without arguments for a guided interactive prompt with smart defaults, or use CLI flags for headless automation.
- **Desktop Notifications**: Optional system notifications via `notify-send` when long batch transcoding jobs complete.
- **Dry-Run Mode**: Inspect files, compute estimates, and test disk space without executing encoding (`-d`).

---

## Requirements

The script uses standard POSIX/GNU utilities and FFmpeg:
- `bash` (v4.0+)
- `ffmpeg` & `ffprobe` (compiled with `zscale` and `libx264` support)
- `coreutils` (`df`, `stat`, `mktemp`, `numfmt`)
- `gawk`
- `libnotify` (*optional*, for desktop completion alerts)

### Installing Dependencies

#### Fedora / RHEL
```bash
# Enable RPM Fusion (required for full FFmpeg with non-free codecs)
sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
                    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Install FFmpeg and required utilities
sudo dnf install -y ffmpeg coreutils gawk libnotify
```

#### Ubuntu / Debian
```bash
sudo apt update
sudo apt install -y ffmpeg coreutils gawk libnotify-bin
```

#### Arch Linux
```bash
sudo pacman -S ffmpeg coreutils gawk libnotify
```

#### macOS (Homebrew)
```bash
brew install bash ffmpeg coreutils gawk

# Add GNU coreutils to PATH (in ~/.zshrc or ~/.bashrc) so numfmt is directly available:
export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$PATH"
```

---

## Installation

### Method 1: Using the Makefile (Recommended)

Install for the current user (`~/.local/bin/transcoder`):
```bash
make install
```
*(Make sure `~/.local/bin` is in your `$PATH`)*

Or install system-wide (`/usr/local/bin/transcoder`):
```bash
sudo make install-system
```

To uninstall:
```bash
make uninstall
# or for system-wide:
sudo make uninstall-system
```

### Method 2: Manual Installation
```bash
chmod +x transcode.sh
mkdir -p ~/.local/bin
cp transcode.sh ~/.local/bin/transcoder
```

---

## Usage

### Interactive Mode
Simply run `transcoder` (or `./transcode.sh`) without arguments. You will be prompted to select:
1. Source folder or video file (supports direct drag-and-drop from file managers with single/double quotes `' '`, tilde `~` expansion, and relative/absolute paths)
2. Recursive directory scan (if subfolders are present)
3. Target codec (ProRes 422 LT or H.264 All-Intra)
4. Target framerate (30 or 60 fps)
5. Destination mode (save to subfolder `transcoded/` or safe in-place overwrite)

```bash
transcoder
```

### Command-Line Options

```
Usage: transcoder [OPTIONS] [INPUT_DIR|FILE]

ARGUMENTS:
  INPUT_DIR|FILE           Source directory or video file to process
                           (Default: current directory)

OPTIONS:
  -f, --format FORMAT      Output codec: prores (Apple ProRes 422 LT) or h264 (All-Intra)
                           (Default: prores)
  -r, --fps FPS            Constant target framerate (CFR): 30 or 60 (Default: 30)
  -i, --input DIR|FILE     Source directory or video file (alternative to positional argument)
  -o, --output DIR         Destination directory for converted videos
                           (Default: <input>/transcoded)
  -w, --overwrite          Replace original source files in-place with transcoded
                           versions one-by-one upon successful conversion
  -R, --recursive          Scan input directory recursively including subfolders
  -d, --dry-run            Scan sources, verify disk space and print estimate
                           without running FFmpeg
  -h, --help               Display help text and exit
```

### Examples

**Transcode current directory to Apple ProRes 422 LT at 30 fps:**
```bash
transcoder
```

**Safely transcode and replace files in-place one-by-one:**
```bash
transcoder ~/Videos/RawFootage -w
```

**Convert a single clip to H.264 All-Intra:**
```bash
transcoder my_clip.mov -f h264
```

**Convert a single clip in-place:**
```bash
transcoder my_clip.mov -w
```

**Process a directory with 60 fps target framerate to a custom output folder:**
```bash
transcoder ~/Videos/RawFootage -r 60 -o ~/Videos/EditingReady
```

**Recursively process an entire directory structure:**
```bash
transcoder ~/Videos/ProjectAlpha -R -f prores
```

**Perform a dry run to inspect clips and check disk capacity:**
```bash
transcoder ~/Videos/RawFootage -d
```

---

## Technical Details

### Video Codecs

| Preset | FFmpeg Codec | Details | Recommended For |
| :--- | :--- | :--- | :--- |
| `prores` | `prores_ks` (profile 1) | 10-bit 4:2:2, Apple ProRes 422 LT, ~45 GB/h @ 1080p30 | Desktop editing workstations, highest color precision |
| `h264` | `libx264` (All-Intra) | 8-bit 4:2:0, CRF 18, `g=1`, ~15 GB/h @ 1080p30 | Laptops, portable drives, balanced storage and performance |

### Color Space & HDR Tone Mapping
When HDR is detected via color transfer characteristics (`arib-std-b67` for HLG, `smpte2084` for HDR10/Dolby Vision) or `bt2020` color primaries:
```
-vf "zscale=t=linear:npl=100,tonemap=hable,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv422p10le"
```
This performs a linear light conversion, applies the filmic **Hable** tone curve to compress highlights gracefully, and tags the stream as standard Rec.709 TV range (`-color_primaries bt709 -color_trc bt709 -colorspace bt709`).

### Disk Space Safety Pre-flight
Before encoding begins, the script calculates:
$$\text{Clip Size} \approx \text{Duration} \times \text{Base Bitrate} \times \left(\frac{\text{Width} \times \text{Height}}{1920 \times 1080}\right) \times \left(\frac{\text{Target FPS}}{30}\right)$$

A safety factor of **1.2x (+20%)** is applied. If available space on the target partition is lower than the requirement, execution is stopped with an informative message.

### Safe Partial Writes & Signal Traps
To avoid leaving corrupted or half-rendered video files in your destination:
1. Videos are encoded as `.target_name.part.mov`.
2. Unix signals (`SIGINT`, `SIGTERM`, `EXIT`) are trapped.
3. If interrupted, the active FFmpeg PID receives `TERM`, the partial file is unlinked, and temporary files in `/tmp` are removed.
4. On successful completion, `.target_name.part.mov` is atomically renamed to `target_name.mov`.

### Safe In-Place Overwrites (`-w` / `--overwrite`)
When running with `-w` / `--overwrite`:
1. **Per-file Transactional Isolation**: Each clip is encoded into a hidden partial file (`.clip.part.mov`) in the source directory.
2. **Zero Incomplete File Risk**: If interrupted (`Ctrl+C` / `SIGINT` / `SIGTERM`) or if FFmpeg errors out on a corrupted file, the partial file is deleted immediately. The source file being processed remains 100% untouched, as do all files yet to be processed.
3. **Atomic Replacement**: Only when FFmpeg exits with code `0` and produces a valid output file, the partial file atomically replaces the original (`.mov` replaces `.mov`; `.mp4`/`.m4v` is replaced with `.mov` and the old source is removed).
4. **Optimized Peak Space Requirement**: Instead of requiring enough free space to duplicate the entire directory, `--overwrite` mode calculates the progressive peak storage required (temporary space for the current file being encoded plus cumulative size differences of previous files + 20% safety margin).

---

## Contributing

Contributions, bug reports, and suggestions are welcome! Please check [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on code style and testing.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
