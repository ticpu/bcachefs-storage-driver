#!/bin/bash
set -euo pipefail

# Pure bcachefs snapshot chain stress test.
# If this loses files, it's a kernel bug — no Go, no podman involved.
#
# Usage: test-snapshot-chain.sh <bcachefs-mountpoint> [depth] [write-per-layer]
#   depth:           number of snapshot generations (default: 50)
#   write-per-layer: write a new file in each snapshot to simulate RUN steps (default: 1)

MOUNT="$(realpath "${1:?Usage: $0 <bcachefs-mountpoint> [depth] [write-per-layer]}")"
DEPTH="${2:-50}"
WRITE_PER_LAYER="${3:-1}"
PREFIX="$MOUNT/@snapshot-chain-test"

cleanup() {
    echo "Cleaning up..."
    for i in $(seq "$DEPTH" -1 0); do
        bcachefs subvolume delete "$PREFIX/layer-$i" 2>/dev/null || true
    done
    rmdir "$PREFIX" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$PREFIX"

echo "=== bcachefs snapshot chain test ==="
echo "Mount:           $MOUNT"
echo "Depth:           $DEPTH"
echo "Write per layer: $WRITE_PER_LAYER"
echo "Kernel:          $(uname -r)"
echo ""

# Layer 0: base subvolume with seed files
echo "Creating base subvolume with seed files..."
bcachefs subvolume create "$PREFIX/layer-0"

# Seed files that must survive the entire chain
mkdir -p "$PREFIX/layer-0/bin" "$PREFIX/layer-0/usr/bin" "$PREFIX/layer-0/etc" "$PREFIX/layer-0/tmp"
echo '#!/bin/dash'          > "$PREFIX/layer-0/bin/sh"
echo '#!/bin/bash'          > "$PREFIX/layer-0/bin/bash"
echo '#!/usr/bin/python3'   > "$PREFIX/layer-0/usr/bin/python3"
echo 'root:x:0:0:root:/root:/bin/bash' > "$PREFIX/layer-0/etc/passwd"
chmod 755 "$PREFIX/layer-0/bin/sh" "$PREFIX/layer-0/bin/bash" "$PREFIX/layer-0/usr/bin/python3"

# Symlinks
ln -s dash "$PREFIX/layer-0/bin/dash-link"
ln -s ../usr/bin "$PREFIX/layer-0/bin/usrbin-link"

SEED_FILES=(bin/sh bin/bash usr/bin/python3 etc/passwd)
SEED_LINKS=(bin/dash-link bin/usrbin-link)

echo "Seed files: ${SEED_FILES[*]}"
echo "Seed links: ${SEED_LINKS[*]}"
echo ""

verify_layer() {
    local layer_path="$1"
    local layer_num="$2"
    local failed=0

    for f in "${SEED_FILES[@]}"; do
        if [ ! -f "$layer_path/$f" ]; then
            echo "FAIL: layer $layer_num: seed file $f MISSING"
            failed=1
        fi
    done

    for l in "${SEED_LINKS[@]}"; do
        if [ ! -L "$layer_path/$l" ]; then
            echo "FAIL: layer $layer_num: symlink $l MISSING"
            failed=1
        fi
    done

    # Verify symlink targets
    local target
    target=$(readlink "$layer_path/bin/dash-link" 2>/dev/null || echo "MISSING")
    if [ "$target" != "dash" ]; then
        echo "FAIL: layer $layer_num: bin/dash-link target = '$target', expected 'dash'"
        failed=1
    fi

    # Verify all previous layer files exist
    for j in $(seq 1 "$((layer_num - 1))"); do
        if [ "$WRITE_PER_LAYER" -eq 1 ] && [ ! -f "$layer_path/tmp/layer-$j.txt" ]; then
            echo "FAIL: layer $layer_num: per-layer file tmp/layer-$j.txt MISSING"
            failed=1
        fi
    done

    return $failed
}

# Create snapshot chain
for i in $(seq 1 "$DEPTH"); do
    prev=$((i - 1))
    bcachefs subvolume snapshot "$PREFIX/layer-$prev" "$PREFIX/layer-$i"

    # Verify seed files survived the snapshot
    if ! verify_layer "$PREFIX/layer-$i" "$i"; then
        echo ""
        echo "========================================="
        echo "BUG REPRODUCED at layer $i"
        echo "========================================="
        echo "Parent: $PREFIX/layer-$prev"
        echo "Child:  $PREFIX/layer-$i"
        echo ""
        echo "Parent contents:"
        find "$PREFIX/layer-$prev" -maxdepth 3 -ls 2>/dev/null || true
        echo ""
        echo "Child contents:"
        find "$PREFIX/layer-$i" -maxdepth 3 -ls 2>/dev/null || true
        echo ""
        echo "This is a bcachefs kernel bug. No Go or podman code is involved."
        echo "Kernel: $(uname -r)"
        echo "bcachefs version: $(bcachefs version 2>/dev/null || echo unknown)"
        exit 1
    fi

    # Simulate a RUN step: write a new file in the snapshot
    if [ "$WRITE_PER_LAYER" -eq 1 ]; then
        echo "layer $i" > "$PREFIX/layer-$i/tmp/layer-$i.txt"
    fi

    # Progress
    if [ $((i % 10)) -eq 0 ] || [ "$i" -eq "$DEPTH" ]; then
        echo "Layer $i/$DEPTH: OK (seed files + ${i} layer files intact)"
    fi
done

echo ""
echo "=== PASS: $DEPTH snapshot generations, all files preserved ==="
echo ""
echo "Subvolumes:"
bcachefs subvolume list -s "$MOUNT" 2>/dev/null | grep snapshot-chain-test || ls -1d "$PREFIX"/layer-*
