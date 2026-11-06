# Contributing to Video Transcoder

Thank you for your interest in contributing to **Video Transcoder**!

## How to Contribute

### Reporting Bugs
- Search existing issues to ensure the bug hasn't already been reported.
- Open a new issue including:
  - Your operating system and FFmpeg version (`ffmpeg -version`).
  - Output of `ffprobe` for the problematic video file.
  - The exact command you ran and terminal output.

### Suggesting Enhancements
- Open a feature request describing the use case and proposed behavior.
- Discuss before submitting large pull requests to ensure alignment with project goals.

### Submitting Pull Requests
1. Fork the repository and create your feature branch:
   ```bash
   git checkout -b feature/my-new-feature
   ```
2. Adhere to code style:
   - Use POSIX/Bash best practices (`set -euo pipefail`).
   - Quote variables properly to handle filenames with spaces and special characters.
   - Run syntax and lint checks:
     ```bash
     bash -n transcode.sh
     # If shellcheck is installed:
     shellcheck transcode.sh
     ```
3. Commit your changes following [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat: add AV1 support`
   - `fix: handle spaces in destination directory name`
   - `docs: improve Fedora installation notes`
4. Open a pull request against the `main` branch.

## Code of Conduct
Be respectful and constructive in all discussions, pull requests, and issue reports.
