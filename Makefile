SHELL := /bin/bash
DESTDIR ?=
PREFIX ?= $(HOME)/.local
SYSTEM_PREFIX ?= /usr/local
BIN_DIR ?= $(DESTDIR)$(PREFIX)/bin
SYSTEM_BIN_DIR ?= $(DESTDIR)$(SYSTEM_PREFIX)/bin
SCRIPT_NAME := transcoder
SOURCE_SCRIPT := transcode.sh

.PHONY: all help install install-system uninstall uninstall-system lint test check

all: help

help:
	@echo "Video Transcoder - Build & Installation Targets"
	@echo ""
	@echo "Usage:"
	@echo "  make install          Install to user bin directory ($(BIN_DIR)/$(SCRIPT_NAME))"
	@echo "  make install-system   Install system-wide ($(SYSTEM_BIN_DIR)/$(SCRIPT_NAME))"
	@echo "  make uninstall        Remove from user bin directory"
	@echo "  make uninstall-system Remove from system-wide bin directory"
	@echo "  make lint             Verify bash syntax and run ShellCheck"
	@echo "  make test             Run test suite"
	@echo "  make check            Run linting and test suite"
	@echo ""

install:
	@mkdir -p "$(BIN_DIR)"
	install -m 0755 "$(SOURCE_SCRIPT)" "$(BIN_DIR)/$(SCRIPT_NAME)"
	@echo "Successfully installed $(SCRIPT_NAME) to $(BIN_DIR)/$(SCRIPT_NAME)"
	@echo "Ensure $(BIN_DIR) is in your PATH."

install-system:
	@mkdir -p "$(SYSTEM_BIN_DIR)"
	install -m 0755 "$(SOURCE_SCRIPT)" "$(SYSTEM_BIN_DIR)/$(SCRIPT_NAME)"
	@echo "Successfully installed $(SCRIPT_NAME) to $(SYSTEM_BIN_DIR)/$(SCRIPT_NAME)"

uninstall:
	@rm -f "$(BIN_DIR)/$(SCRIPT_NAME)"
	@echo "Removed $(BIN_DIR)/$(SCRIPT_NAME)"

uninstall-system:
	@rm -f "$(SYSTEM_BIN_DIR)/$(SCRIPT_NAME)"
	@echo "Removed $(SYSTEM_BIN_DIR)/$(SCRIPT_NAME)"

check: lint test

test:
	@echo "Running tests..."
	@bash tests/test_path_handling.sh

lint:
	@echo "Checking syntax with bash -n..."
	bash -n "$(SOURCE_SCRIPT)"
	bash -n tests/test_path_handling.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running ShellCheck..."; \
		shellcheck "$(SOURCE_SCRIPT)" tests/test_path_handling.sh; \
	else \
		echo "ShellCheck not found. Skipped ShellCheck step."; \
	fi
	@echo "Syntax check passed."
