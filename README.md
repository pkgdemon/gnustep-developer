# gnustep-developer

This is intended for GNUstep developers only.  This is my build system to automate installing/updating stock GNUstep to quality patches. 

## Supported Operating Systems

* FreeBSD
* Arch Linux
* Debian
* Devuan (Debian without systems and with sys v init instead)
* NextBSD

## Requirements for building

* root access
* git (e.g., `pkg install git-lite`) (NOTE: Need to use `/usr/local/bin/git` on FreeBSD freshly installed system when chrooted at the end of the installation)

## Building from source, installation and uninstallation

After installing, configuring the above requirements run the following commands as root:

```
git clone https://github.com/pkgdemon/gnustep-developer.git /Developer
cd /Developer && make install
```

`make install` runs the whole sequence itself: `bootstrap.sh` (build
dependencies), `checkout.sh` (sources into `Library/Sources`), the full system
domain build, and finally `dscli init` to set up Directory Services. Every step
is idempotent, so the same command also updates an existing installation.  To
update simply run make install again.

This installs GNUstep in /System, enables services for DirectoryServices, and creates a user admin with no password.  All new users can be managed with dicli, each user added with have it's home folder in /Local/Users.

To build against the sources already checked out, without bootstrapping or
refreshing them, use `make system` instead.

To remove GNUstep installed from sources run the following as root:

```
cd /Developer && make uninstall
```

Data will be kept in /Local, /Network, and /Volumes folder will persist but can be removed manually if no longer in use.  

## Requirements for usage

* xorg or xlibre
* At runtime, the packages mentioned in the respective `.dependencies` file

## Usage

After making sure usage requirements are met the following should be run as regular user to start GNUstep after logging in as admin user no password:

```
xinit
```

## Build targets

`make install` builds and installs the entire system domain. The build is also
split into granular targets so a single component can be (re)built on its own —
useful for CI and incremental development. Every per-component target requires
the core libraries to be installed first (`make corelibs`). All targets run as
root, like `make install`.

| Target | Builds |
| --- | --- |
| `corelibs` | core libraries (libdispatch, libobjc2, tools-make, libs-base, libs-gui, libs-back) plus gnustep-system, gnustep-assets |
| `workspace` | apps-workspace |
| `dock` | apps-dock (DockWM) |
| `systempreferences` | apps-systempreferences |
| `terminal` | gap |
| `textedit` | gnustep-textedit |
| `windowmanager` | gnustep-windowmanager |
| `components` | gershwin-components (DirectoryServices) |
| `dubstep-theme` | dubstep-dark-theme (GSTheme bundle, installed to /System/Library/Themes) |
| `dscli-init` | runs `dscli init` (Directory Services: /Local skeleton, admin account, nsswitch and sudoers) |

For example, build the core libraries once and then just (re)build the workspace:

```
cd /Developer
make corelibs
make workspace
```

## Pinned upstream libraries

Only `swift-corelibs-libdispatch`) is
checked out at pinned commits by default so that the sources we build are the
sources the patches in `Library/Patches/` were written against. Without the pins
an upstream commit can silently break a patch and fail the build.

To check whether a pin can be advanced, build against the upstream HEADs
instead:

```
PINNED=0 /Developer/Library/Scripts/checkout.sh
```

The pins live in the `PINS` list at the top of `checkout.sh`.

## Skipping repositories during checkout

`checkout.sh` clones every repository the build needs. Set `SKIP_REPOS` to a
space- or comma-separated list of repository names to skip cloning/updating some
of them — handy when you provide a repository's sources yourself (for example a
CI checkout of the component under test, symlinked into `Library/Sources/`):

```
SKIP_REPOS="apps-gworkspace gap" /Developer/Library/Scripts/checkout.sh
```

## Building against a development or feature branch

By default `checkout.sh` clones each repository's default branch. Set `BRANCH`
to build against another branch instead — most commonly a `dev` branch holding
work in progress *before it lands in the default branch*:

```
BRANCH=dev /Developer/Library/Scripts/checkout.sh
```

`BRANCH` is generic — any branch name works — so it doubles as a tool for
testing a feature branch across repositories:

```
BRANCH=my-feature /Developer/Library/Scripts/checkout.sh
```

For each repository that **has** the named branch, it is cloned/checked out on
that branch; repositories **without** it fall back to their default branch, so a
partial rollout (where only some repos have the branch yet) just works. The run
logs which repository used the branch and prints a summary at the end. Leaving
`BRANCH` unset keeps the previous behaviour, and `BRANCH` can be combined with
`PINNED` and `SKIP_REPOS`.
