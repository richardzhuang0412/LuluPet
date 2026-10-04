#!/bin/bash
# Renders the README demo GIFs / MP4s into docs/demo/ (see tools/make_demos.py). Nothing shows on screen.
#   tools/make_demos.sh [scene…] [--keep] [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."
VENV=build/demo-venv
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c "import PIL, imageio_ffmpeg" 2>/dev/null; then
    echo "Setting up $VENV (Pillow + imageio-ffmpeg)…"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q pillow imageio-ffmpeg
fi
exec nice -n 10 "$VENV/bin/python" tools/make_demos.py "$@"
