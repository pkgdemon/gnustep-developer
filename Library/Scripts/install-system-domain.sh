#!/bin/sh
set -e

if [ "$FROM_MAKEFILE" != "1" ]; then
    echo "This script must be run from the Makefile."
    exit 1
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
export PATH="${PATH}:$SCRIPTS_DIR"
. ./Library/Scripts/functions.sh
detect_platform
export_vars

export REPOS_DIR="$WORKDIR/Library/Sources"

# The Gershwin domain is a clang toolchain end to end: the ng-gnu-gnu library
# combo is built on libobjc2, and the cmake stages already pin
# -DCMAKE_C_COMPILER=clang. The autoconf stages, though, let configure pick its
# own default, which on Linux is gcc. That is not just an inconsistency - on
# Debian bookworm (gcc 12) libs-corebase's AC_CHECK_HEADERS([dispatch/dispatch.h])
# fails against the libdispatch headers we just installed and configure aborts
# with "Could not find the Grand Central Dispatch headers.". On the BSDs cc is
# already clang, so this is a no-op there. An explicit CC/CXX/OBJC in the
# environment still wins, so a deliberate override is unaffected.
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
export OBJC="${OBJC:-clang}"

# Autoconf 2.72+ AC_PROG_CC silently upgrades CC to "$CC -std=gnu23" whenever
# the compiler supports C23, and tools-make records that upgraded CC in
# gnustep-make's config.make. GNUstep is not C23-clean: in C23 "int f()" means
# "int f(void)", so gnustep-base's weak forward declaration of
# gnustep_base_user_main conflicts with its own definition and NSProcessInfo.m
# fails to compile. Only the BSDs hit it - Linux has HAVE_PROCFS, which
# preprocesses that whole block away. Caching the C23 probe as "no" makes
# configure fall through to the C11 probe, which clang passes with no extra
# flag, so CC stays plain "clang" everywhere - including in config.make, which
# keeps apps-gworkspace's "$CC must equal gnustep-config --variable=CC" check
# satisfied.
export ac_cv_prog_cc_c23=no

# Detect NextBSD - libdispatch is provided by the base system
if [ -d "/usr/lib/system" ]; then
  NEXTBSD=1
  echo "NextBSD detected: base ships a HAVE_MACH libdispatch in /usr/lib/system (daemons);"
  echo "  the Gershwin domain builds its own non-Mach libdispatch into /System/Library/Libraries"
  # config.guess does not recognize NextBSD; tell configure we are FreeBSD
  ARCH=$(uname -m)
  case "$ARCH" in
    amd64) ARCH="x86_64" ;;
  esac
  BUILD_FLAG="--build=${ARCH}-nextbsd-freebsd"
  CMAKE_SYSTEM_FLAG="-DCMAKE_SYSTEM_NAME=FreeBSD"
else
  NEXTBSD=0
  BUILD_FLAG=""
  CMAKE_SYSTEM_FLAG=""
fi

# On OpenBSD, X11 headers/libs live under /usr/X11R6, which clang does not search
# by default. Export the flags once here so they apply to every build stage:
#   - CFLAGS/OBJCFLAGS/CPPFLAGS let the compilers (and autoconf configure scripts)
#     find the X11 headers.
#   - LDFLAGS and LIBRARY_PATH let the linker find libX11 regardless of how a given
#     package's makefiles handle link flags.
if [ "$(uname -s)" = "OpenBSD" ]; then
  export CFLAGS="${CFLAGS:+$CFLAGS }-I/usr/X11R6/include"
  export OBJCFLAGS="${OBJCFLAGS:+$OBJCFLAGS }-I/usr/X11R6/include"
  export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/X11R6/include"
  export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/X11R6/lib"
  export LIBRARY_PATH="/usr/X11R6/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

# Source the GNUstep environment, which is installed by the corelibs stage via
# tools-make.  The corelibs stage sources it itself at the right moment, so this
# is only used by the individual app/component stages when they are run on their
# own (e.g. "make workspace" in CI after "make corelibs").
ensure_gnustep_env() {
  if [ ! -f /System/Library/Makefiles/GNUstep.sh ]; then
    echo "GNUstep environment not found at /System/Library/Makefiles/GNUstep.sh."
    echo "Build the core libraries first:  make corelibs"
    exit 1
  fi
  . /System/Library/Makefiles/GNUstep.sh
  export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"
}

build_corelibs() {
  cd "$REPOS_DIR/gnustep-system"
  $MAKE_CMD install
  export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

  cd "$REPOS_DIR/gnustep-assets"
  cp -R Library/* /System/Library/

  # Patch libdispatch (FreeBSD timer-spin fix; harmless on other platforms).
  echo "Patching libdispatch..."
  patch.sh swift-corelibs-libdispatch

  # Gershwin apps must link the portable, NON-Mach libdispatch. On stock
  # FreeBSD/Linux this happens automatically (no <mach/mach.h> present, so the
  # HAVE_MACH code is never compiled). NextBSD, however, ships libmach's
  # <mach/mach.h> system-wide, so libdispatch's `#if __has_include(<mach/mach.h>)`
  # guards auto-enable the Darwin Mach/QoS (direct-knote) event backend. That
  # backend is wrong for FreeBSD's kqueue (0x0100 == EV_FORCEONESHOT; udata is not
  # part of knote identity) and breaks GNUstep's fd-based dispatch sources — most
  # visibly, the global menu's WindowMonitor never tracks the frontmost app.
  # So on NextBSD we force those guards off to reproduce the stock non-Mach build
  # and install it to /System/Library/Libraries, which Gershwin binaries' RUNPATH
  # resolves ahead of /usr/lib/system. The NextBSD base's HAVE_MACH libdispatch in
  # /usr/lib/system is left in place for the system daemons (launchd/XPC/notifyd).
  DISPATCH_EXTRA_FLAGS=""
  if [ "$NEXTBSD" -eq 1 ]; then
    echo "NextBSD: forcing non-Mach libdispatch for the Gershwin domain"
    ( cd "$REPOS_DIR/swift-corelibs-libdispatch" && \
      grep -rl "__has_include(<mach/mach.h>)" . 2>/dev/null | grep -vE "/\.git/|/Build/" | \
      xargs -r sed -i.nbsdbak "s#__has_include(<mach/mach.h>)#0#g" )
    DISPATCH_EXTRA_FLAGS="-DHAVE_MACH=OFF"
  fi

  # Build libdispatch first - provides BlocksRuntime needed by tools-make configure
  echo "Building/installing libdispatch..."
  if [ -d "$REPOS_DIR/swift-corelibs-libdispatch/Build" ] ; then
    rm -rf "$REPOS_DIR/swift-corelibs-libdispatch/Build"
  fi
  mkdir -p "$REPOS_DIR/swift-corelibs-libdispatch/Build"

  cd "$REPOS_DIR/swift-corelibs-libdispatch/Build"

  # $CMAKE_SYSTEM_FLAG (-DCMAKE_SYSTEM_NAME=FreeBSD on NextBSD, empty elsewhere):
  # without it CMake can't match NextBSD's uname to a platform module, so it never
  # sets CMAKE_SHARED_LIBRARY_SONAME_C_FLAG and emits libBlocksRuntime.so with no
  # SONAME — which makes libdispatch record a build-relative NEEDED
  # (../libBlocksRuntime.so) that fails to load. Telling CMake it's FreeBSD lets it
  # set the soname itself, exactly like the base and libobjc2 builds do.
  cmake .. \
    $CMAKE_SYSTEM_FLAG \
    -DCMAKE_INSTALL_PREFIX=/System/Library \
    -DCMAKE_INSTALL_LIBDIR=Libraries \
    -DINSTALL_DISPATCH_HEADERS_DIR=/System/Library/Headers/dispatch \
    -DINSTALL_BLOCK_HEADERS_DIR=/System/Library/Headers \
    -DINSTALL_OS_HEADERS_DIR=/System/Library/Headers/os \
    -DINSTALL_PRIVATE_HEADERS=ON \
    -DCMAKE_INSTALL_MANDIR=Documentation/man \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    $DISPATCH_EXTRA_FLAGS

  "$MAKE_CMD" -j"$CPUS" || exit 1
  "$MAKE_CMD" install || exit 1

  # Build tools-make - can now find _Block_copy in libdispatch's BlocksRuntime
  # Use libobjc_LIBS=" " to prevent configure from adding -lobjc to link tests
  echo "Building/installing tools-make..."
  cd "$REPOS_DIR/tools-make"
  $MAKE_CMD distclean 2>/dev/null || true
  # $BUILD_FLAG is --build=<arch>-nextbsd-freebsd on NextBSD (config.guess can't
  # recognize NextBSD's uname), empty elsewhere — harmless on FreeBSD/Linux.
  ./configure \
    $BUILD_FLAG \
    --with-config-file=/System/Library/Preferences/GNUstep.conf \
    --with-layout=gershwin \
    --with-library-combo=ng-gnu-gnu \
    --with-objc-lib-flag=" " \
    LDFLAGS="-L/System/Library/Libraries" \
    CPPFLAGS="-I/System/Library/Headers" \
    libobjc_LIBS=" "
  $MAKE_CMD || exit 1
  $MAKE_CMD install

  . /System/Library/Makefiles/GNUstep.sh

  # Build libobjc2 - gnustep-config now available for paths
  echo "Building/installing libobjc2..."
  if [ -d "$REPOS_DIR/libobjc2/Build" ] ; then
    rm -rf "$REPOS_DIR/libobjc2/Build"
  fi
  mkdir -p "$REPOS_DIR/libobjc2/Build"

  cd "$REPOS_DIR/libobjc2/Build"

  cmake .. \
    -DGNUSTEP_INSTALL_TYPE=SYSTEM \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DEMBEDDED_BLOCKS_RUNTIME=OFF \
    -DBlocksRuntime_INCLUDE_DIR=/System/Library/Headers \
    -DBlocksRuntime_LIBRARIES=/System/Library/Libraries/libBlocksRuntime.so

  "$MAKE_CMD" -j"$CPUS" || exit 1
  "$MAKE_CMD" install || exit 1

  export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

  cd "$REPOS_DIR/libs-base"

  if [ "$NEXTBSD" -eq 1 ]; then
    # NextBSD ships libdns_sd (the mDNSResponder DNS-SD client) in
    # /usr/lib/system, which is on binaries' runtime RUNPATH but is NOT a
    # default link-time search dir. Without -L/usr/lib/system, libs-base
    # configure's AC_CHECK_LIB(dns_sd, DNSServiceBrowse) link test fails, so
    # HAVE_MDNS is set to 0 and NSNetServiceBrowser/NSNetService are built with
    # NO zeroconf backend: their +allocWithZone: then returns nil and the
    # [[NSNetServiceBrowser alloc] init] in the Network view SIGSEGVs
    # (Workspace, NetworkBrowser, RemoteDesktop). Adding the -L makes the mDNS
    # backend detect+link. /System/Library/Libraries is listed FIRST so
    # dispatch/objc/BlocksRuntime keep linking from the Gershwin (non-Mach)
    # domain; /usr/lib/system is only for the base-only libdns_sd. Runtime
    # dispatch resolution is unchanged (governed by RUNPATH, verified via ldd).
    ./configure \
      $BUILD_FLAG \
      --with-dispatch-include=/usr/include \
      --with-dispatch-library=/System/Library/Libraries \
      --with-zeroconf-api=mdns \
      LDFLAGS="-L/System/Library/Libraries -L/usr/lib/system"
  else
    ./configure \
      --with-dispatch-include=/System/Library/Headers \
      --with-dispatch-library=/System/Library/Libraries
  fi
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  cd "$REPOS_DIR/libs-corebase"
  ./configure \
    $BUILD_FLAG \
    CPPFLAGS="-I/System/Library/Headers" \
    LDFLAGS="-L/System/Library/Libraries"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  cd "$REPOS_DIR/libs-gui"
  ./configure $BUILD_FLAG
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  cd "$REPOS_DIR/libs-opal"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  cd "$REPOS_DIR/libs-back"
  export fonts=no
  ./configure $BUILD_FLAG
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  cd "$REPOS_DIR/libs-quartzcore"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  cd "$REPOS_DIR/libs-av"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_workspace() {
  cd "$REPOS_DIR/apps-gworkspace"
  # OpenBSD ships autoconf and automake with version-suffixed binaries;
  # autoreconf needs these env vars to pick the right versions.
  if [ "$(uname -s)" = "OpenBSD" ]; then
    export AUTOCONF_VERSION
    export AUTOMAKE_VERSION
    AUTOCONF_VERSION=$(ls /usr/local/bin/autoconf-* 2>/dev/null | sed 's|.*/autoconf-||' | sort -V | tail -1)
    AUTOMAKE_VERSION=$(ls /usr/local/bin/automake-* 2>/dev/null | sed 's|.*/automake-||' | sort -V | tail -1)
    echo "Using AUTOCONF_VERSION=$AUTOCONF_VERSION AUTOMAKE_VERSION=$AUTOMAKE_VERSION"
  fi
  autoreconf -fi
  ./configure $BUILD_FLAG
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_dock() {
  cd "$REPOS_DIR/apps-dock"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_systempreferences() {
  cd "$REPOS_DIR/apps-systempreferences"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_terminal() {
  cd "$REPOS_DIR/gap/system-apps/Terminal"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_textedit() {
  cd "$REPOS_DIR/gnustep-textedit"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_windowmanager() {
  cd "$REPOS_DIR/gnustep-windowmanager/"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_components() {
  # Components with a .DISABLED file in their directory will not be built
  cd "$REPOS_DIR/gnustep-components/DirectoryServices/"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_dubstep_theme() {
  # GSTheme bundle; installs to /System/Library/Themes/Dubstep.theme.
  # Selecting it is left to the user (System Preferences > Themes, or
  # "defaults write NSGlobalDomain GSTheme Dubstep").
  cd "$REPOS_DIR/dubstep-dark-theme"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

run_dscli_init() {
  # Initialise Directory Services: the /Local skeleton, the default admin
  # account, and the nsswitch/sudoers wiring.  This is idempotent - an
  # existing Users.plist/Groups.plist is left alone - so it is safe to run
  # on every install.  dscli is installed by the components stage.
  if ! command -v dscli >/dev/null 2>&1; then
    echo "dscli not found on PATH. Build the components first:  make components"
    exit 1
  fi

  # "dscli init" bakes the current PATH into sudoers' secure_path, so run it
  # with this script's own directory filtered out - the build tree has no
  # business being on every sudo invocation's PATH.
  _clean_path=""
  _old_ifs="$IFS"
  IFS=:
  for _dir in $PATH; do
    [ "$_dir" = "$SCRIPTS_DIR" ] && continue
    _clean_path="${_clean_path:+$_clean_path:}$_dir"
  done
  IFS="$_old_ifs"

  PATH="$_clean_path" dscli init
}

# Dispatch on the requested target.  Default "all" reproduces the original
# end-to-end System Domain install in the exact same order.
TARGET="${1:-all}"
case "$TARGET" in
  corelibs)
    build_corelibs
    ;;
  workspace)
    ensure_gnustep_env
    build_workspace
    ;;
  dock)
    ensure_gnustep_env
    build_dock
    ;;
  systempreferences)
    ensure_gnustep_env
    build_systempreferences
    ;;
  terminal)
    ensure_gnustep_env
    build_terminal
    ;;
  textedit)
    ensure_gnustep_env
    build_textedit
    ;;
  windowmanager)
    ensure_gnustep_env
    build_windowmanager
    ;;
  components)
    ensure_gnustep_env
    build_components
    ;;
  dubstep-theme)
    ensure_gnustep_env
    build_dubstep_theme
    ;;
  dscli-init)
    ensure_gnustep_env
    run_dscli_init
    ;;
  all)
    build_corelibs
    build_workspace
    build_dock
    build_systempreferences
    build_terminal
    build_textedit
    build_windowmanager
    build_components
    build_dubstep_theme
    ;;
  *)
    echo "Unknown target: $TARGET"
    echo "Valid targets: corelibs workspace dock systempreferences terminal textedit windowmanager components dubstep-theme dscli-init all"
    exit 1
    ;;
esac

echo ""
echo "Done."
