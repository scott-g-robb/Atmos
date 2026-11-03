#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"
./scripts/build-weather-core.sh
cargo test --quiet --locked --manifest-path weather-core/Cargo.toml
swift test -c release "$@"
