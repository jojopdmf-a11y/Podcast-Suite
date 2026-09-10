#!/bin/zsh
# Double-click in Finder: pull GitHub, rebuild, launch Fixer Mixer.
cd "$(dirname "$0")"
chmod +x "scripts/update-and-launch.sh"
exec "./scripts/update-and-launch.sh" fixer
