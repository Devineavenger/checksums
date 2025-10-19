# checksums

[![CI](https://github.com/yourname/checksums/actions/workflows/ci.yml/badge.svg)](https://github.com/yourname/checksums/actions/workflows/ci.yml)
[![Release](https://github.com/yourname/checksums/actions/workflows/release.yml/badge.svg)](https://github.com/yourname/checksums/actions/workflows/release.yml)

A lightweight shell utility for generating and verifying file checksums, with a fully automated developer workflow:

- 🛠️ Makefile targets for install, test, lint, release, and changelog management
- 📦 Release automation via release.sh and GitHub Actions
- 📝 Changelog lifecycle with [Unreleased] sections, draft updates on PRs, and automatic promotion on release
- ✅ CI/CD pipelines for pre-flight checks, changelog previews, and GitHub Releases

---

## ✨ Features

- Generate and verify checksums for files
- Simple installation (make install or ./install.sh)
- Unit tests with Bats
- Linting with ShellCheck
- Automated release process:
  - Bump version in VERSION and checksums.sh
  - Promote [Unreleased] → vX.Y.Z in CHANGELOG.md
  - Reinsert fresh [Unreleased] section
  - Build tarball in dist/
  - Publish GitHub Release with grouped notes
- CI/CD integration:
  - make check runs lint + tests + changelog preview
  - PRs get a sticky changelog preview comment
  - Draft changelog entries auto-committed to PR branches
  - Tagged releases auto-published

---

## 🚀 Installation

### Developer-style install
    make install

### Friendly user install
    ./install.sh

### Uninstall
    make uninstall
    # or
    ./uninstall.sh

---

## 🧪 Development Workflow

### Run tests
    make test

### Lint scripts
    make lint

### Local CI check
    make ci

### Pre-flight check (lint + test + changelog preview)
    make check

---

## 📦 Building & Releasing

### Build tarball
    make dist

### Cut a release
    make release NEW_VER=2.6.0

This will:
- Update VERSION and checksums.sh
- Promote [Unreleased] → v2.6.0 - YYYY-MM-DD in CHANGELOG.md
- Reinsert a fresh [Unreleased] section
- Commit and tag v2.6.0
- Build dist/checksums-2.6.0.tar.gz
- Create a GitHub Release (if gh CLI is available)

---

## 📝 Changelog Lifecycle

- **PRs**:
  - make changelog-draft appends commits to [Unreleased] in CHANGELOG.md
  - CI auto-commits this back to the PR branch
  - A sticky PR comment shows the preview

- **Releases**:
  - release.sh promotes [Unreleased] → vX.Y.Z - YYYY-MM-DD
  - Reinserts a fresh [Unreleased] section for the next cycle

- **Grouped sections** (if commits follow Conventional Commits):
  - feat: → Features
  - fix: → Fixes
  - docs: → Documentation
  - chore: → Chores
  - refactor: → Refactoring
  - test: → Tests

---

## ⚙️ Makefile Targets

| Target | Description |
|--------|-------------|
| make install | Install checksums (developer style) |
| make uninstall | Uninstall checksums |
| make user-install | Run friendly install.sh |
| make uninstall-user | Run friendly uninstall.sh |
| make test | Run unit tests (Bats) |
| make lint | Run ShellCheck linting |
| make ci | Run lint + test |
| make check | Run lint + test + changelog preview |
| make version | Print current version |
| make dist | Build versioned tarball in ./dist/ |
| make release NEW_VER=x.y.z | Run release.sh with given version |
| make changelog | Preview changelog entries since last tag |
| make changelog-draft | Insert draft changelog into CHANGELOG.md |
| make clean | Remove dist/ and temp files |
| make help | Show help message |

---

## 🤖 CI/CD Workflows

### .github/workflows/ci.yml
- Runs on PRs and pushes to main
- Jobs:
  - build: runs make check, posts changelog preview as sticky PR comment
  - changelog-draft: runs make changelog-draft, commits updated CHANGELOG.md back to PR branch

### .github/workflows/release.yml
- Runs on tag pushes (v*)
- Jobs:
  - Runs release.sh with version from tag
  - Promotes [Unreleased] → versioned section
  - Reinserts fresh [Unreleased]
  - Commits updated CHANGELOG.md, VERSION, and checksums.sh back to main
  - Publishes GitHub Release with tarball and notes

---

## 🛡️ Commit Conventions

To get clean grouped changelogs, follow Conventional Commits:

- feat: add new hashing algorithm
- fix: correct install.sh permissions
- docs: update README with release instructions

---

## 📖 Example Workflow

1. Developer opens PR with commits like:
       feat: add SHA512 support
       fix: correct checksum verification bug
2. CI posts a sticky PR comment with grouped changelog preview.
3. CI auto-updates [Unreleased] in CHANGELOG.md and commits it to the PR branch.
4. Maintainer merges PR.
5. Maintainer tags v2.6.0.
6. release.yml runs release.sh 2.6.0, promotes changelog, reinserts [Unreleased], builds tarball, and publishes GitHub Release.

---

## 📜 License

MIT License. See LICENSE for details.
