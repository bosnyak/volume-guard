#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_SRC="$ROOT_DIR/build/VolumeGuard.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

if [ ! -d "$DRIVER_SRC" ]; then
    echo "Driver not built yet. Running scripts/build.sh first..."
    "$ROOT_DIR/scripts/build.sh"
fi

echo "Installing VolumeGuard.driver into $HAL_DIR (requires sudo)..."
sudo mkdir -p "$HAL_DIR"
sudo rm -rf "$HAL_DIR/VolumeGuard.driver"
sudo cp -R "$DRIVER_SRC" "$HAL_DIR/VolumeGuard.driver"
sudo chown -R root:wheel "$HAL_DIR/VolumeGuard.driver"
sudo chmod -R 755 "$HAL_DIR/VolumeGuard.driver"

echo "Reloading macOS CoreAudio daemon..."
sudo pkill -9 -f 'Core Audio Driver' || true
sudo killall -9 coreaudiod || sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || true
sleep 0.5
killall ControlCenter 2>/dev/null || true

echo "✅ VolumeGuard.driver installed and CoreAudio reloaded!"
