#!/usr/bin/env bash
set -euo pipefail

# Build all Soroban smart contracts for wasm32-unknown-unknown target and generate
# release artifact metadata with toolchain information and git source revision (#51).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "=== Building Soroban contracts for wasm32-unknown-unknown ==="
cargo build --locked --workspace --target wasm32-unknown-unknown --release

OUT_DIR="$ROOT_DIR/target/wasm32-unknown-unknown/release"
mkdir -p "$OUT_DIR"

SOURCE_REVISION="${SOURCE_REVISION:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}"
TOOLCHAIN_VERSION="$(rustc --version)"
BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
METADATA_FILE="$OUT_DIR/artifact-metadata.json"

echo "=== Generating release artifact metadata ==="
python3 -c "
import os, sys, json, hashlib

out_dir = sys.argv[1]
source_rev = sys.argv[2]
toolchain = sys.argv[3]
timestamp = sys.argv[4]

artifacts = []
if os.path.exists(out_dir):
    for fname in sorted(os.listdir(out_dir)):
        if fname.endswith('.wasm'):
            fpath = os.path.join(out_dir, fname)
            with open(fpath, 'rb') as f:
                content = f.read()
                sha256 = hashlib.sha256(content).hexdigest()
            artifacts.append({
                'filename': fname,
                'size_bytes': len(content),
                'sha256': sha256
            })

meta = {
    'schema_version': '1.0',
    'toolchain': toolchain,
    'source_revision': source_rev,
    'build_timestamp': timestamp,
    'target': 'wasm32-unknown-unknown',
    'artifacts': artifacts
}

out_meta = os.path.join(out_dir, 'artifact-metadata.json')
with open(out_meta, 'w') as f:
    json.dump(meta, f, indent=2)

print(f'Recorded metadata for {len(artifacts)} Wasm artifacts -> {out_meta}')
" "$OUT_DIR" "$SOURCE_REVISION" "$TOOLCHAIN_VERSION" "$BUILD_TIMESTAMP"

echo "=== Contract build completed successfully ==="
