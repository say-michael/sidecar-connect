# sidecar-connect — build & install
#
# Usage:
#   make            # build ./sidecar-connect
#   make install    # install to $(PREFIX)/bin  (default: /usr/local)
#   make uninstall  # remove the installed binary
#   make dump-api   # build the SidecarCore API introspection helper
#   make clean      # remove build artifacts

BINARY  := sidecar-connect
PREFIX  ?= /usr/local
BINDIR  := $(PREFIX)/bin
SWIFTC  ?= swiftc
SWIFTFLAGS ?= -O

.PHONY: all build install uninstall dump-api clean

all: build

build: $(BINARY)

$(BINARY): src/main.swift
	$(SWIFTC) $(SWIFTFLAGS) src/main.swift -o $(BINARY)

install: build
	@mkdir -p "$(BINDIR)"
	install -m 0755 $(BINARY) "$(BINDIR)/$(BINARY)"
	@echo "Installed $(BINDIR)/$(BINARY)"

uninstall:
	@rm -f "$(BINDIR)/$(BINARY)"
	@echo "Removed $(BINDIR)/$(BINARY)"

dump-api: tools/dump-api.swift
	$(SWIFTC) $(SWIFTFLAGS) tools/dump-api.swift -o dump-api

clean:
	rm -f $(BINARY) dump-api
