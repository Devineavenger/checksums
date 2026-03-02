PREFIX        ?= /usr/local
BINDIR        ?= $(PREFIX)/bin
SHAREDIR      ?= $(PREFIX)/share/checksums
LIBDIR        ?= $(SHAREDIR)/lib
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

.PHONY: all install uninstall user-install user-uninstall \
	tests lint dos2unix ci version dist release changelog changelog-draft \
	clean check help newfile addheader addheaders addheaders-recursive _positional

_positional:
	@true

# Default target
all: help

install:
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(LIBDIR)
	install -m 0755 $(MAIN_SCRIPT) $(DESTDIR)$(BINDIR)/checksums
	# copy lib scripts if any exist
	@if ls lib/*.sh >/dev/null 2>&1; then \
	  install -m 0644 lib/*.sh $(DESTDIR)$(LIBDIR)/; \
	else \
	  true; \
	fi

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/checksums
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
	tmp=$$(mktemp -d); \
	mkdir -p "$$tmp/$$name"; \
	cp -a $(MAIN_SCRIPT) $(VERSION_FILE) Makefile README.md LICENSE.md docs scripts lib tests .github "$$tmp/$$name/" 2>/dev/null || true; \
	tar -C "$$tmp" -czf dist/$$name.tar.gz "$$name"; \
	rm -rf "$$tmp"
	
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
	mkdir -p docs; \
	{ \
	    echo "## [Unreleased] - $$DATE"; \
	    echo ""; \
	    echo "$$CHANGES"; \
	    echo ""; \
	    cat docs/CHANGELOG.md 2>/dev/null || true; \
	} > CHANGELOG.tmp; \
	mv CHANGELOG.tmp docs/CHANGELOG.md; \
	echo "✅ Draft changelog inserted at top of docs/CHANGELOG.md"

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
	@echo "  make release NEW_VER=x.y.z - Cut a release; changelog auto-generated from commits if [Unreleased] is empty"
	@echo "  make changelog             - Preview changelog entries since last tag"
	@echo "  make changelog-draft       - Insert draft changelog into docs/CHANGELOG.md"
	@echo "  make clean                 - Remove dist/ and temp files"
	@echo "  make newfile FILE=...      - Create new file with license header"
	@echo "  make addheader FILE=...    - Prepend license header to one file"
	@echo "  make addheaders DIR=...    - Prepend license header to all files in a directory"
	@echo "  make addheaders-recursive DIR=... - Prepend license header to all .md/.sh/Makefile files recursively
