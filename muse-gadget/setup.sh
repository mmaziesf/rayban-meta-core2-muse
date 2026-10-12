#!/usr/bin/env bash
# Clones Meta's Muse Gadget SDK at the commit these patches were tested on and
# applies them on a branch named core2-v1.1.
#
#   muse-gadget/setup.sh [DIR]     (default: ./muse-gadget-sdk next to this repo)
set -euo pipefail

UPSTREAM=https://github.com/facebookincubator/muse-gadget-sdk
BASE=812c46f9fe42b69d916613a9dc702cbac5ff7b54   # 2026-10-09, "Fix StopWatch controls ..." (#163)
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${1:-$HERE/../../muse-gadget-sdk}

if [ ! -d "$DIR/.git" ]; then
  git clone "$UPSTREAM" "$DIR"
fi
cd "$DIR"
git fetch -q origin
git checkout -q -B core2-v1.1 "$BASE"
git -c user.name="${GIT_AUTHOR_NAME:-patches}" -c user.email="${GIT_AUTHOR_EMAIL:-patches@localhost}" \
  am -q --committer-date-is-author-date "$HERE"/patches/*.patch
echo "Muse Gadget SDK ready at $(pwd) on branch core2-v1.1:"
git log --oneline -3
