# sidecar-connect — build & install
#
# Usage:
#   make              # build ./sidecar-connect
#   make install      # install to $(PREFIX)/bin  (default: /usr/local)
#   make uninstall    # remove the installed binary
#   make install-agent    # install + load the login auto-connect LaunchAgent
#   make uninstall-agent  # unload + remove the LaunchAgent
#   make dump-api     # build the SidecarCore API introspection helper
#   make clean        # remove build artifacts

BINARY  := sidecar-connect
PREFIX  ?= /usr/local
BINDIR  := $(PREFIX)/bin
SWIFTC  ?= swiftc
SWIFTFLAGS ?= -O

AGENT_LABEL := com.user.sidecar-connect
AGENT_SRC   := dist/$(AGENT_LABEL).plist
AGENT_DIR   := $(HOME)/Library/LaunchAgents
AGENT_DEST  := $(AGENT_DIR)/$(AGENT_LABEL).plist

.PHONY: all build install uninstall install-agent uninstall-agent dump-api clean

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

# Install + load the login auto-connect LaunchAgent. Substitutes the real install
# path into the plist template and bootstraps it for the current GUI session.
install-agent: install
	@mkdir -p "$(AGENT_DIR)"
	@sed 's#__BINDIR__#$(BINDIR)#g' "$(AGENT_SRC)" > "$(AGENT_DEST)"
	@launchctl bootout gui/$$(id -u)/$(AGENT_LABEL) 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) "$(AGENT_DEST)"
	@echo "Installed and loaded $(AGENT_DEST)"
	@echo "Edit the device name in that file if it isn't an 'iPad'."

uninstall-agent:
	@launchctl bootout gui/$$(id -u)/$(AGENT_LABEL) 2>/dev/null || true
	@rm -f "$(AGENT_DEST)"
	@echo "Unloaded and removed $(AGENT_DEST)"

dump-api: tools/dump-api.swift
	$(SWIFTC) $(SWIFTFLAGS) tools/dump-api.swift -o dump-api

clean:
	rm -f $(BINARY) dump-api
