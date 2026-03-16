PREFIX        ?= /usr/local
BINDIR        ?= $(PREFIX)/bin
SHAREDIR      ?= $(PREFIX)/share/checksums
LIBDIR        ?= $(SHAREDIR)/lib
MANDIR        ?= $(PREFIX)/share/man/man1
BASH_COMPDIR  ?= $(PREFIX)/share/bash-completion/completions
ZSH_COMPDIR   ?= $(PREFIX)/share/zsh/site-functions
MAIN_SCRIPT   := checksums.sh
VERSION_FILE  := VERSION
DESTDIR       ?=

# Positional args for FILE/DIR (e.g., make addheader docs/CONTRIBUTING.md)
FILE ?= $(word 2,$(MAKECMDGOALS))
DIR  ?= $(word 2,$(MAKECMDGOALS))

# Deduplicate and consume positional goals so they aren't treated as targets
ARGS := $(sort $(strip $(FILE) $(DIR)))

# Prefer reading the license header from a file to avoid exporting a large multi-line env var.
LICENSE_HEADER_FILE := scripts/LICENSE
export LICENSE_HEADER_FILE

.PHONY: all install uninstall user-install user-uninstall user-reinstall \
	tests lint dos2unix ci version dist release changelog changelog-draft \
	clean check help newfile addheader addheaders addheaders-recursive \
	man man-preview _positional

_positional:
	@true

# Default target
all: help

install:
	@printf '==> Installing checksums %s\n' "$$(cat VERSION 2>/dev/null || echo unknown)"
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(LIBDIR)
	install -m 0644 VERSION $(DESTDIR)$(SHAREDIR)/
	install -m 0755 $(MAIN_SCRIPT) $(DESTDIR)$(BINDIR)/checksums
	# copy lib scripts if any exist
	@if ls lib/*.sh >/dev/null 2>&1; then \
	  install -m 0644 lib/*.sh $(DESTDIR)$(LIBDIR)/; \
	else \
	  true; \
	fi
	@if [ -f docs/checksums.1 ]; then \
	  install -d $(DESTDIR)$(MANDIR); \
	  install -m 0644 docs/checksums.1 $(DESTDIR)$(MANDIR)/checksums.1; \
	fi
	@if [ -f completions/checksums.bash ]; then \
	  install -d $(DESTDIR)$(BASH_COMPDIR); \
	  install -m 0644 completions/checksums.bash $(DESTDIR)$(BASH_COMPDIR)/checksums; \
	fi
	@if [ -f completions/_checksums ]; then \
	  install -d $(DESTDIR)$(ZSH_COMPDIR); \
	  install -m 0644 completions/_checksums $(DESTDIR)$(ZSH_COMPDIR)/_checksums; \
	fi
	@printf '==> Installed checksums %s to %s\n' "$$(cat VERSION 2>/dev/null || echo unknown)" "$(DESTDIR)$(PREFIX)"

uninstall:
	@if [ -r "$(DESTDIR)$(SHAREDIR)/VERSION" ]; then \
	  printf '==> Uninstalling checksums %s\n' "$$(cat $(DESTDIR)$(SHAREDIR)/VERSION)"; \
	else \
	  printf '==> Uninstalling checksums\n'; \
	fi
	rm -f $(DESTDIR)$(BINDIR)/checksums
	rm -f $(DESTDIR)$(MANDIR)/checksums.1
	rm -f $(DESTDIR)$(BASH_COMPDIR)/checksums
	rm -f $(DESTDIR)$(ZSH_COMPDIR)/_checksums
	rm -rf $(DESTDIR)$(SHAREDIR)

user-install:
	@bash ./scripts/install.sh

user-uninstall:
	@bash ./scripts/uninstall.sh

user-reinstall:
	@bash ./scripts/uninstall.sh
	sleep 0.3
	@bash ./scripts/install.sh

tests:
	@bash ./tests/run-bats.sh

lint:
	shellcheck $(MAIN_SCRIPT) lib/*.sh
	@if ls completions/*.bash >/dev/null 2>&1; then shellcheck completions/*.bash; fi

dos2unix:
	@./scripts/dos2unix.sh

ci: lint tests
	@echo "✅ Local CI checks passed"

version:
	@printf 'checksums version: '
	@if [ -f $(VERSION_FILE) ]; then cat $(VERSION_FILE); \
	else grep -m1 '^# Version:' $(MAIN_SCRIPT) | awk '{print $$3}'; fi

dist:
	@ver=$$(cat $(VERSION_FILE) 2>/dev/null || echo "dev"); \
	name="checksums-$$ver"; \
	echo "📦 Building $$name.tar.gz"; \
	mkdir -p dist; \
	tmp=$$(mktemp -d); \
	mkdir -p "$$tmp/$$name"; \
	cp -a $(MAIN_SCRIPT) $(VERSION_FILE) Makefile README.md LICENSE.md docs scripts lib tests completions .github "$$tmp/$$name/" 2>/dev/null || true; \
	tar -C "$$tmp" -czf dist/$$name.tar.gz "$$name"; \
	rm -rf "$$tmp"

man: docs/checksums.1

docs/checksums.1: docs/checksums.1.in VERSION
	@ver=$$(cat VERSION); \
	date_str=$$(LC_ALL=C date +'%B %Y'); \
	sed -e "s/%%VERSION%%/$$ver/g" -e "s/%%DATE%%/$$date_str/g" \
	    docs/checksums.1.in > docs/checksums.1
	@printf '==> Generated docs/checksums.1 (version %s)\n' "$$(cat VERSION)"

man-preview: man
	@man ./docs/checksums.1

release:
	@if [ -z "$(NEW_VER)" ]; then \
	    echo "❌ Usage: make release NEW_VER=x.y.z [FLAGS='--prerelease --draft']"; \
	    exit 1; \
	fi
	@if [ ! -f ./scripts/release.sh ]; then \
	    echo "❌ release.sh not found"; \
	    exit 1; \
	fi
	@bash ./scripts/release.sh $(NEW_VER) $(FLAGS)

changelog:
	@LAST_TAG=$$(git describe --tags --abbrev=0 --exclude '*-*' 2>/dev/null || echo ""); \
	if [ -n "$$LAST_TAG" ]; then \
	    echo "==> Changelog since $$LAST_TAG"; \
	    git log "$$LAST_TAG"..HEAD --pretty=format:"* %s" --no-merges; \
	else \
	    echo "==> Full changelog (no previous tags)"; \
	    git log --pretty=format:"* %s" --no-merges; \
	fi

changelog-draft:
	@LAST_TAG=$$(git describe --tags --abbrev=0 --exclude '*-*' 2>/dev/null || echo ""); \
	if [ -n "$$LAST_TAG" ]; then \
	    echo "==> Writing draft changelog since $$LAST_TAG"; \
	    CHANGES=$$(git log "$$LAST_TAG"..HEAD --pretty=format:"* %s" --no-merges); \
	else \
	    echo "==> Writing full changelog (no previous tags)"; \
	    CHANGES=$$(git log --pretty=format:"* %s" --no-merges); \
	fi; \
	mkdir -p docs; \
	if grep -q '^\#\# \[Unreleased\]' docs/CHANGELOG.md 2>/dev/null; then \
	    echo "==> [Unreleased] section already exists; skipping prepend"; \
	else \
	    { \
	        echo "## [Unreleased]"; \
	        echo ""; \
	        echo "$$CHANGES"; \
	        echo ""; \
	        cat docs/CHANGELOG.md 2>/dev/null || true; \
	    } > CHANGELOG.tmp; \
	    mv CHANGELOG.tmp docs/CHANGELOG.md; \
	    echo "✅ Draft changelog inserted at top of docs/CHANGELOG.md"; \
	fi

clean:
	@echo "🧹 Cleaning build artifacts and temporary files"
	@echo "-> removing distribution files"
	@find dist -maxdepth 1 -type f -name '*.tar.gz' -print -exec rm -f -- {} \; 2>/dev/null || true
	@echo "-> removing backup files (*.bak, *~)"
	@find . -type f \( -name '*.bak' -o -name '*~' \) -print -exec rm -f -- {} \;
	@echo "-> removing changelog temp files"
	@find . -type f \( -name 'CHANGELOG.tmp' -o -name 'changelog.tmp.*' \) -print -exec rm -f -- {} \;
	@echo "-> removing generic .tmp files (excluding dist)"
	@find . -type f -name '*.tmp' -not -path './dist/*' -print -exec rm -f -- {} \;
	@echo "-> removing specific temp patterns"
	@find . -type f \( -name 'checksums.sh.tmp.*' -o -name 'lib.init.tmp.*' -o -name '.license.tmp.*' -o -name '.license.new.*' \) -print -exec rm -f -- {} \;
	@echo "-> removing lock directories (attempt rmdir then rm -rf)"
	@find . -type d -name '*.lock' -print -exec rmdir {} \; 2>/dev/null || true
	@find . -type d -name '*.lock' -print -exec rm -rf -- {} \; 2>/dev/null || true
	@echo "-> removing .build"
	@rm -rf .build || true
	@echo "🧹 Done"

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
	@echo "  make install                      - Install checksums to PREFIX (default: /usr/local)"
	@echo "  make uninstall                    - Uninstall checksums from PREFIX"
	@echo "  make user-install                 - Run interactive ./scripts/install.sh"
	@echo "  make user-uninstall               - Run interactive ./scripts/uninstall.sh"
	@echo "  make user-reinstall               - Uninstall then reinstall (interactive)"
	@echo "  make tests                        - Run unit tests (Bats)"
	@echo "  make lint                         - Run shellcheck on all shell sources"
	@echo "  make dos2unix                     - Normalise line endings in all sources"
	@echo "  make ci                           - Run lint + tests (local CI gate)"
	@echo "  make check                        - Run lint + tests + changelog preview"
	@echo "  make version                      - Print current tool version"
	@echo "  make dist                         - Build versioned tarball in ./dist/"
	@echo "  make release NEW_VER=x.y.z        - Cut a release (bump version, promote"
	@echo "                                      changelog, tag, push); pre-write entries"
	@echo "                                      under ## [Unreleased] or leave empty for"
	@echo "                                      auto-generated notes from commits"
	@echo "  make changelog                    - Preview commits since last release tag"
	@echo "  make changelog-draft              - Prepend [Unreleased] draft to CHANGELOG"
	@echo "                                      (skipped if [Unreleased] already exists)"
	@echo "  make man                          - Generate man page from template"
	@echo "  make man-preview                  - Generate and preview man page"
	@echo "  make clean                        - Remove dist tarballs and temp files"
	@echo "  make newfile FILE=path            - Create new file with license header"
	@echo "  make addheader FILE=path          - Prepend license header to one file"
	@echo "  make addheaders DIR=path          - Add headers to all files in a directory"
	@echo "  make addheaders-recursive DIR=path - Add headers recursively (.sh/.md/Makefile)"
