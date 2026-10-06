ifeq ($(shell uname -s),Darwin)
PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)
BINDIR ?= $(PREFIX)/bin
else
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/sbin
endif
LIBDIR ?= $(PREFIX)/lib/net-tap
BASH ?= bash

export PYTHONDONTWRITEBYTECODE = 1

all: lint

install:
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(LIBDIR)
	install -m 755 bin/net-tap.sh $(DESTDIR)$(BINDIR)/net-tap
	install -m 644 lib/*.sh $(DESTDIR)$(LIBDIR)/
	install -m 755 lib/*.py $(DESTDIR)$(LIBDIR)/

installcheck:
	@echo "Checking installed net-tap binary..."
	@$(DESTDIR)$(BINDIR)/net-tap -h >/dev/null && echo "installcheck passed!"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/net-tap
	rm -rf $(DESTDIR)$(LIBDIR)

lint:
	@echo "Running ShellCheck on scripts..."
	@if command -v shellcheck >/dev/null 2>&1; then \
		set -e; \
		shellcheck bin/net-tap.sh lib/*.sh tests/run_tests.sh tests/run_macos_tests.sh tests/run_macos_capture_test.sh && echo "ShellCheck passed!"; \
	else \
		echo "Error: shellcheck is not installed. Failing lint step." >&2; \
		exit 1; \
	fi
	@echo "Checking Python fixture generator and probe syntax..."
	@if command -v python3 >/dev/null 2>&1; then \
		python3 -B -c "import ast; ast.parse(open('tests/generate_carrier_fixtures.py').read()); ast.parse(open('lib/probe.py').read())" && echo "Python syntax passed!"; \
	fi
	@echo "Validating Draft-7 analysis JSON schema..."
	@if command -v python3 >/dev/null 2>&1; then \
		python3 -B -c "import json, jsonschema; s = json.load(open('tests/schema/analysis.schema.json')); jsonschema.Draft7Validator.check_schema(s); print('Schema valid!')"; \
	fi

fixtures:
	@echo "Regenerating synthetic carrier fixtures..."
	@if command -v python3 >/dev/null 2>&1; then \
		python3 -B tests/generate_carrier_fixtures.py; \
	else \
		echo "Python 3 is required to generate fixtures." >&2; \
		exit 1; \
	fi

ifeq ($(shell uname -s),Darwin)
test: lint fixtures
	@echo "Running macOS capture/analysis and platform-boundary tests..."
	@$(BASH) tests/run_macos_tests.sh

test-integration:
	@echo "Linux network namespace integration tests are unavailable on macOS." >&2
	@exit 1
else
test: lint fixtures
	@echo "Running automated compliance and unit tests..."
	@$(BASH) tests/run_tests.sh

test-integration: lint fixtures
	@echo "Running integration tests (requires root)..."
	@sudo PYTHONDONTWRITEBYTECODE=1 $(BASH) tests/run_tests.sh
endif

clean:
	@rm -rf tests/__pycache__ "$${TMPDIR:-/tmp}/pmtud.pcap"
	@for path in "$${TMPDIR:-/tmp}"/net-tap-*; do \
		[ -e "$$path" ] || continue; \
		if [ "$$(uname -s)" = Darwin ]; then owner=$$(stat -f '%u' "$$path" 2>/dev/null); \
		else owner=$$(stat -c '%u' "$$path" 2>/dev/null); fi; \
		[ "$$owner" = "$$(id -u)" ] && rm -rf "$$path"; \
	done

.PHONY: all install installcheck uninstall lint fixtures test test-integration clean
