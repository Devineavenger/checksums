# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# checksums

[![License: Source-Available, Non-Commercial](https://img.shields.io/badge/license-source--available%20(non--commercial)-orange)](LICENSE.md)
[![Redistribution: Prohibited](https://img.shields.io/badge/redistribution-prohibited-red)](LICENSE.md)
[![Commercial Use: Forbidden](https://img.shields.io/badge/commercial--use-forbidden-darkred)](LICENSE.md)
[![Derivative Distribution: Not Allowed](https://img.shields.io/badge/derivative--distribution-not--allowed-lightgrey)](LICENSE.md)
[![Version](https://img.shields.io/github/v/release/Devineavenger/checksums?sort=semver&display_name=tag)](https://github.com/Devineavenger/checksums/releases)
[![Downloads](https://img.shields.io/github/downloads/Devineavenger/checksums/total?label=downloads)](https://github.com/Devineavenger/checksums/releases)
[![Tests](https://github.com/Devineavenger/checksums/actions/workflows/test.yml/badge.svg)](https://github.com/Devineavenger/checksums/actions/workflows/test.yml)
[![CI](https://github.com/Devineavenger/checksums/actions/workflows/ci.yml/badge.svg)](https://github.com/Devineavenger/checksums/actions/workflows/ci.yml)
[![Release](https://github.com/Devineavenger/checksums/actions/workflows/release.yml/badge.svg)](https://github.com/Devineavenger/checksums/actions/workflows/release.yml)

⚠️ **Usage Note**: This tool is **source‑available for non‑commercial internal use only**.  
You may study and modify it for yourself or your organization, but redistribution, commercial use, and publishing modified versions are prohibited.  
See LICENSE.md for full terms.

### ⚖️ Legal Status

This project is **source‑available but not OSI‑approved open source**.  
You may view, study, and modify the code for personal, educational, or internal use.  
However, redistribution, commercial use, and distribution of modified versions are explicitly prohibited under the license terms.  
See LICENSE.md for details.

### ❓ Why Source‑Available?

This project is licensed as **source‑available** rather than open source to strike a balance:  
- ✅ You can freely **study, learn from, and use** the code for personal, educational, or internal purposes.  
- ✅ You can **modify it privately** to fit your own workflows.  
- ❌ You cannot **redistribute, commercialize, or publish** modified versions.  

The intent is to **share knowledge and tooling without enabling commercial exploitation**.  
It ensures individuals and teams can benefit internally, while the author retains control over distribution and commercial rights.

### License FAQ

**Can I use this at work?**  
✅ Yes, if it’s for internal use only (e.g., inside your company for builds or audits).  
❌ You cannot resell, redistribute, or offer it as a service.

**Can I redistribute the tool?**  
❌ No. Redistribution of the source code, binaries, or modified versions is not allowed.

**Can I publish my modifications?**  
❌ No. You may modify the software for your own use, but you cannot distribute modified versions.

**Can I use it commercially?**  
❌ No. Selling, renting, leasing, or offering it as part of a paid product or service is prohibited.

**Can I study the code and learn from it?**  
✅ Yes. Studying and learning from the code is explicitly permitted.

**Is there any warranty?**  
❌ No. The software is provided “as is,” without warranty of any kind. See the disclaimer in LICENSE.md.

### License Summary

| Allowed                                   | Not Allowed                                |
|-------------------------------------------|--------------------------------------------|
| ✅ Personal use                            | ❌ Redistribution of source or binaries     |
| ✅ Educational use                         | ❌ Commercial use (selling, renting, SaaS)  |
| ✅ Internal/company use                    | ❌ Publishing modified versions             |
| ✅ Studying and modifying for yourself     | ❌ Derivative distribution                  |

---

## ✨ Features

- **Checksums:** Generate and verify checksums for files and directories
- **Sidecar manifests:**
  - `.md5` or `.sha256` per‑file hashes
  - `.meta` with inode/dev/mtime/size + signature
  - `.log` per‑directory logs with rotation
- **Configurable algorithms:**
  - `-a md5 | sha256` per‑file hashing
  - `-m sha256 | md5 | none` meta signature
- **Policies:**
  - `--skip-empty` (default) avoids sidecars in empty/container‑only dirs
  - `--allow-root-sidefiles` permits sidecars in root (disabled by default)
  - `--no-reuse` disables reuse heuristics
- **Modes:**
  - Normal run: create/update manifests
  - Verify-only (`-V`): audit integrity without writes
  - Dry-run (`-n`): simulate actions without writes
  - First-run (`-F`): bootstrap `.meta`/`.log` from legacy `.md5`
- **Performance:** Parallel hashing (`-p N`) with adaptive batching (`-b RULES`)
- **Debug helpers:**
  - `debug_run.sh` runs `process_single_directory` in isolation
  - `run-with-instrument.sh` wraps `md5sum`/`sha256sum` to log timings
- **Developer workflow:**
  - Unit tests with Bats
  - Linting with ShellCheck
  - Automated release process (`release.sh`)
  - CI/CD pipelines for pre‑flight checks, changelog previews, and GitHub Releases

---

## 🚀 Installation

Friendly user install:
	make user-install
	or
    ./scripts/install.sh

Friendly user uninstall:
    make user-uninstall
	or
    ./scripts/uninstall.sh
	
Reinstall with new Version:
    make user-reinstall
	or
	./scripts/uninstall.sh
	./scripts/install.sh

Developer-style install:
    make install
	
Developer-style uninstall:
    make uninstall

---

## 🧭 Usage

Quick start:
    checksums /path/to/project

Defaults:
- md5 per‑file hashes
- sha256 meta signatures
- skip empty/container‑only directories
- no sidecars in root
- reuse heuristics enabled
- single worker (`-p 1`)
- confirmation prompt before processing

Run `checksums --help` for full CLI options. Highlights:
- `-F, --first-run` bootstrap mode
- `-V, --verify-only` audit mode
- `-n, --dry-run` simulation mode
- `-p N, --parallel N` parallel hashing jobs
- `-b RULES, --batch RULES` adaptive batching
- `--skip-empty / --no-skip-empty`
- `--allow-root-sidefiles`

### Quick Examples
    checksums -a sha256 -o json --assume-yes /data/project
    checksums --config /data/project/custom.conf -V /data/project
    checksums --allow-root-sidefiles /data/project
    checksums -F -C overwrite /data/project

### Common Usage Patterns

First-run Bootstrap:
    checksums -F -C overwrite -a md5 -m sha256 -p 4 --md5-details --skip-empty /data/project

Verify-only Audit:
    checksums -V -a md5 -m sha256 -p 4 --md5-details --skip-empty --assume-yes /data/project

Dry-run Planning:
    checksums -n -a sha256 -m sha256 -p 4 -v --md5-details --skip-empty --assume-yes /data/project

---

## 🧪 Development Workflow

- Run tests: `make tests`
- Lint scripts: `make lint`
- Local CI check: `make ci`
- Pre-flight check: `make check`

Debug helpers:
- `./scripts/debug_run.sh` → runs `process_single_directory` in a temp dir, logs state
- `./scripts/run-with-instrument.sh --log /tmp/instr.log -- checksums …` → wraps hash tools to log timings

---

## 📦 Building & Releasing

- Build tarball: `make dist`
- Cut a release: `make release NEW_VER=x.y.z`

Release automation (`release.sh`):
- Updates VERSION, checksums.sh, lib/init.sh
- Promotes `[Unreleased]` → versioned section in docs/CHANGELOG.md
- Reinserts fresh `[Unreleased]`
- Builds dist tarball
- Commits, tags, pushes
- Publishes GitHub Release with grouped notes

---

## 📝 Changelog Lifecycle

- PRs: `make changelog-draft` appends commits to `[Unreleased]`
- Releases: `release.sh` promotes `[Unreleased]` → versioned section
- Grouped sections (Conventional Commits):
  - feat → Features
  - fix → Fixes
  - docs → Documentation
  - chore → Chores
  - refactor → Refactoring
  - test → Tests

---

## ⚙️ Makefile Targets

make install                 — Install checksums (developer style)
make uninstall               — Uninstall checksums
make user-install            — Run friendly install.sh
make user-uninstall          — Run friendly uninstall.sh
make user-reinstall          — Uninstall then install
make tests                   — Run unit tests (Bats)
make lint                    — Run ShellCheck linting
make ci                      — Run lint + test
make check                   — Run lint + test + changelog preview
make version                 — Print current version
make dist                    — Build versioned tarball in ./dist/
make release NEW_VER=x.y.z   — Run release.sh with given version
make changelog               — Preview changelog entries since last tag
make changelog-draft         — Insert draft changelog into docs/CHANGELOG.md
make dos2unix                — Normalize CRLF → LF for common text files (runs ./scripts/dos2unix.sh)
make clean                   — Remove dist/ and temp files
make help                    — Show help message

---

## 📖 Example Workflow

1. Developer opens PR with commits like:
       feat: add SHA512 support
       fix: correct checksum verification bug
2. CI posts a sticky PR comment with grouped changelog preview.
3. CI auto-updates `[Unreleased]` in docs/CHANGELOG.md and commits it to the PR branch.
4. Maintainer merges PR.
5. Maintainer tags v3.7.5.
6. `release.yml` runs `scripts/release.sh`, promotes changelog, reinserts `[Unreleased]`, builds tarball, and publishes GitHub Release.

---

## 📜 License

This project uses a **custom source‑available license**.  
You are free to use, study, and modify the software for personal, educational, or internal purposes, but redistribution, commercial use, and distribution of modified versions are not permitted.  

See LICENSE.md for the full terms.
