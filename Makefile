check_root:
	@if [ `id -u` -ne 0 ]; then \
		echo "This Makefile must be run as root or with sudo."; \
		exit 1; \
	fi

# Full end-to-end install: pull in the build dependencies, refresh the sources,
# build and install the system domain, then initialise Directory Services.
# Every step is idempotent, so this is also the way to update an existing
# installation.
install: check_root
	@sh ./Library/Scripts/bootstrap.sh
	@sh ./Library/Scripts/checkout.sh
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh all
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh dscli-init

# Build and install the system domain only, against the sources already in
# Library/Sources. Does not bootstrap, check out or initialise anything.
system: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh all; \

# Granular build targets. Each builds a single component from
# Library/Sources, assuming the core libraries are already installed
# (run "make corelibs" first). Useful for per-repo CI.
corelibs: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh corelibs

workspace: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh workspace

dock: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh dock

systempreferences: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh systempreferences

terminal: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh terminal

textedit: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh textedit

windowmanager: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh windowmanager

components: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh components

dubstep-theme: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh dubstep-theme

dscli-init: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh dscli-init

uninstall: check_root
	@if [ -d "/usr/lib/system" ]; then \
	  echo "NextBSD system detected (/usr/lib/system exists)."; \
	  echo "Cannot uninstall /System on NextBSD as it may contain system libraries."; \
	elif [ -d "/System/Library" ]; then \
	  rm -rf /System >/dev/null 2>&1 || true; \
	  echo "Removed GNUstep System Domain /System"; \
	  echo "Uninstallation complete: /System"; \
	else \
	  echo "GNUstep appears to be already uninstalled. Nothing was removed."; \
	fi
