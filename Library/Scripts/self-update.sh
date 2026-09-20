#!/bin/sh
set -e

# Refresh this repository itself before the sources are checked out, so an
# existing installation picks up new scripts and patches. Non-fatal: a missing
# remote, a detached HEAD, local changes or no network all leave the working
# tree exactly as it is.
#
# Skip it entirely (e.g. in CI, which supplies its own checkout) with:
#   SELF_UPDATE=0 make install

SELF_UPDATE="${SELF_UPDATE:-1}"

if [ "$SELF_UPDATE" = "0" ]; then
	echo "SELF_UPDATE=0; skipping self-update."
	exit 0
fi

# Run from the repository root regardless of where we were invoked from.
cd "$(dirname "$0")/../.."
REPO_DIR=$(pwd)

if ! command -v git >/dev/null 2>&1; then
	echo "git not found; skipping self-update."
	exit 0
fi

if [ ! -d .git ]; then
	echo "Not a git checkout; skipping self-update."
	exit 0
fi

# "make install" runs as root, so the checkout is usually owned by another
# user. Mark it safe rather than having git refuse to touch it.
git config --global --get-all safe.directory 2>/dev/null | grep -qx "$REPO_DIR" \
	|| git config --global --add safe.directory "$REPO_DIR"

echo "Updating gnustep-developer checkout..."
git pull --ff-only || echo "git pull failed; continuing with the current checkout."
