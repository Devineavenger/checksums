PREFIX		?= /usr/local
BINDIR		?= $(PREFIX)/bin
SHAREDIR	  ?= $(PREFIX)/share/checksums
LIBDIR		?= $(SHAREDIR)/lib
MAIN_SCRIPT   := checksums.sh
VERSION_FILE  := VERSION

.PHONY: all install uninstall user-install user-uninstall \
	test lint ci version dist release changelog changelog-draft \
	clean check help

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
	./install.sh

user-uninstall:
	./uninstall.sh

test:
	bats tests/

lint:
	shellcheck $(MAIN_SCRIPT) lib/*.sh

ci: lint test
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
	$(MAIN_SCRIPT) $(VERSION_FILE) Makefile install.sh uninstall.sh lib tests .github

release:
	@if [ -z "$(NEW_VER)" ]; then \
	echo "❌ Usage: make release NEW_VER=x.y.z [FLAGS='--prerelease --draft']"; \
	exit 1; \
	fi
	@if [ ! -x ./release.sh ]; then \
	echo "❌ release.sh not found or not executable"; \
	exit 1; \
	fi
	./release.sh $(NEW_VER) $(FLAGS)

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
check: lint test changelog
	@echo "🚀 All checks passed and changelog preview generated"

help:
	@echo "Available targets:"
	@echo "  make install				- Install checksums (developer style, quiet)"
	@echo "  make uninstall				- Uninstall checksums (developer style)"
	@echo "  make user-install			- Run friendly ./install.sh script"
	@echo "  make user-uninstall		- Run friendly ./uninstall.sh script"
	@echo "  make test					- Run unit tests (Bats)"
	@echo "  make lint					- Run shellcheck linting"
	@echo "  make ci					- Run lint + test (local CI check)"
	@echo "  make check					- Run lint + test + changelog preview"
	@echo "  make version				- Print current tool version"
	@echo "  make dist					- Build a versioned tarball in ./dist/"
	@echo "  make release NEW_VER=x.y.z	- Run ./release.sh with given version"
	@echo "  make changelog				- Preview changelog entries since last tag"
	@echo "  make changelog-draft		- Insert draft changelog into CHANGELOG.md"
	@echo "  make clean					- Remove dist/ and temp files"
	@echo "  make help					- Show this help message"
