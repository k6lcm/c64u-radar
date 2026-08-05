#!/bin/sh
# Double-click this file in Finder to start the C64 Ultimate Radar server.
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 was not found on this Mac."
    echo "Install it from https://www.python.org/downloads/, or run"
    echo "'xcode-select --install' in Terminal for Apple's version, then try again."
    echo
    printf "Press Return to close this window..."
    read _
    exit 1
fi

python3 ultimate_radar_server.py

echo
printf "Server stopped. Press Return to close this window..."
read _
