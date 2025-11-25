PREFIX        ?= /usr/local
BINDIR        ?= $(PREFIX)/bin
SHAREDIR      ?= $(PREFIX)/share/checksums
LIBDIR        ?= $(SHAREDIR)/lib
MAIN_SCRIPT   := checksums.sh
VERSION_FILE  := VERSION

# Positional args for FILE/DIR (e.g., make addheader CONTRIBUTING.md)
FILE ?= $(word 2,$(MAKECMDGOALS))
DIR  ?= $(word 2,$(MAKECMDGOALS))

# Deduplicate and consume positional goals so they aren't treated as targets
ARGS := $(sort $(strip $(FILE) $(DIR)))
$(ARGS):
	@true

# License header (multi-line, literal newlines)
define LICENSE_HEADER
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.
endef

export LICENSE_HEADER

.PHONY: all install uninstall user-install user-uninstall \
	tests lint dos2unix ci version dist release changelog changelog-draft \
	clean check help newfile addheader addheaders addheaders-recursive

# Default target
all: help

install:
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(LIBDIR)
	install -m 0755 $(MAIN_SCRIPT) $(DESTDIR)$(BINDIR)/checksums
	install -m 0644 lib/*.sh $(DESTDIR)$(LIBDIR)/

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/checksums
	rm -rf $(DESTDIR)$(SHAREDIR)

user-install:
	./scripts/install.sh

user-uninstall:
	./scripts/uninstall.sh

user-reinstall:
	./scripts/uninstall.sh
	sleep 1
	./scripts/install.sh

tests:
	./tests/run-bats.sh

lint:
	shellcheck $(MAIN_SCRIPT) lib/*.sh
	
dos2unix:
	./scripts/dos2unix.sh

ci: lint tests
	@echo "✅ Local CI checks passed"

version:
	@echo -n "checksums version: "
	@if [ -f $(VERSION_FILE) ]; then cat $(VERSION_FILE); \
	else grep -m1 '^# Version:' $(MAIN_SCRIPT) | awk '{print $$3}'; fi

dist:
	@ver=$$(cat $(VERSION_FILE) 2>/dev/null || echo "dev"); \
	name="checksums-$$ver"; \
	echo "📦 Building $$name.tar.gz"; \
	mkdir -p dist; \
	tar --exclude=dist -czf dist/$$name.tar.gz \
	--transform "s,^,$$name/," \
	$(MAIN_SCRIPT) $(VERSION_FILE) Makefile scripts lib tests .github

release:
	@if [ -z "$(NEW_VER)" ]; then \
	    echo "❌ Usage: make release NEW_VER=x.y.z [FLAGS='--prerelease --draft']"; \
	    exit 1; \
	fi
	@if [ ! -x ./scripts/release.sh ]; then \
	    echo "❌ release.sh not found or not executable"; \
	    exit 1; \
	fi
	./scripts/release.sh $(NEW_VER) $(FLAGS)

changelog:
	@LAST_TAG=$$(git describe --tags --abbrev=0 2>/dev/null || echo ""); \
	if [ -n "$$LAST_TAG" ]; then \
	    echo "==> Changelog since $$LAST_TAG"; \
	    git log "$$LAST_TAG"..HEAD --pretty=format:"* %s" --no-merges; \
	else \
	    echo "==> Full changelog (no previous tags)"; \
	    git log --pretty=format:"* %s" --no-merges; \
	fi

changelog-draft:
	@LAST_TAG=$$(git describe --tags --abbrev=0 2>/dev/null || echo ""); \
	DATE=$$(date +"%Y-%m-%d"); \
	if [ -n "$$LAST_TAG" ]; then \
	    echo "==> Writing draft changelog since $$LAST_TAG"; \
	    CHANGES=$$(git log "$$LAST_TAG"..HEAD --pretty=format:"* %s" --no-merges); \
	else \
	    echo "==> Writing full changelog (no previous tags)"; \
	    CHANGES=$$(git log --pretty=format:"* %s" --no-merges); \
	fi; \
	{ \
	    echo "## [Unreleased] - $$DATE"; \
	    echo ""; \
	    echo "$$CHANGES"; \
	    echo ""; \
	    cat CHANGELOG.md 2>/dev/null || true; \
	} > CHANGELOG.tmp; \
	mv CHANGELOG.tmp CHANGELOG.md; \
	echo "✅ Draft changelog inserted at top of CHANGELOG.md"

clean:
	rm -rf dist
	find . -name '*.bak' -delete
	find . -name '*~' -delete
	@echo "🧹 Cleaned build artifacts"

# Meta‑target: run lint, tests, and changelog preview
check: lint tests changelog
	@echo "🚀 All checks passed and changelog preview generated"

# License header automation (delegated to scripts/license-tool.sh)
newfile:
	@./scripts/license-tool.sh newfile "$(FILE)"

addheader:
	@./scripts/license-tool.sh addheader "$(FILE)"

addheaders:
	@./scripts/license-tool.sh addheaders "$(DIR)"

addheaders-recursive:
	@./scripts/license-tool.sh addheaders-recursive "$(DIR)"

help:
	@echo "Available targets:"
	@echo "  make install               - Install checksums (developer style, quiet)"
	@echo "  make uninstall             - Uninstall checksums (developer style)"
	@echo "  make user-install          - Run friendly ./scripts/install.sh script"
	@echo "  make user-uninstall        - Run friendly ./scripts/uninstall.sh script"
	@echo "  make user-reinstall        - Run friendly ./scripts/uninstall.sh & ./scripts/install.sh script"
	@echo "  make tests                 - Run unit tests (Bats)"
	@echo "  make lint                  - Run shellcheck linting"
	@echo "  make ci                    - Run lint + test (local CI check)"
	@echo "  make check                 - Run lint + test + changelog preview"
	@echo "  make version               - Print current tool version"
	@echo "  make dist                  - Build a versioned tarball in ./dist/"
	@echo "  make release NEW_VER=x.y.z - Run ./scripts/release.sh with given version"
	@echo "  make changelog             - Preview changelog entries since last tag"
	@echo "  make changelog-draft       - Insert draft changelog into CHANGELOG.md"
	@echo "  make clean                 - Remove dist/ and temp files"
	@echo "  make newfile FILE=...      - Create new file with license header"
	@echo "  make addheader FILE=...    - Prepend license header to one file"
	@echo "  make addheaders DIR=...    - Prepend license header to all files in a directory"
	@echo "  make addheaders-recursive DIR=... - Prepend license header to all .md/.sh/Makefile files recursively
