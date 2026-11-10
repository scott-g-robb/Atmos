#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || { echo "Rust is required to build the weather core. Install it from https://rustup.rs" >&2; exit 1; }
mkdir -p .build/weather-core
export MACOSX_DEPLOYMENT_TARGET=14.0
for architecture in aarch64 x86_64; do
    target="$architecture-apple-darwin"
    if ! rustup target list --installed | /usr/bin/grep -qx "$target"; then rustup target add "$target"; fi
    cargo build --quiet --release --locked --manifest-path weather-core/Cargo.toml --target "$target"
done
lipo -create weather-core/target/{aarch64,x86_64}-apple-darwin/release/libaeolian_weather_core.a -output .build/weather-core/libaeolian_weather_core.a
