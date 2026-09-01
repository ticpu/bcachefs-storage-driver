#!/bin/bash
set -euo pipefail

# Generate release notes. Installation goes through apt.ticpu.net and the AUR,
# so the notes no longer carry per-file curl lines; the artifact directories are
# still read to prove every platform produced packages, since a release whose
# notes describe packages that were never built is worse than a failed build.
#
# Usage: release-notes.sh <dist-dir> > NOTES.md
#
# <dist-dir> holds one subdirectory per upload-artifact name: arch-pkgs/,
# noble-debs/, resolute-debs/, trixie-debs/.

[[ $# -eq 1 ]] || { echo "usage: release-notes.sh <dist-dir>" >&2; exit 2; }

dist="$1"

require() {
    local dir="$1"
    shift
    local f
    for f in "$@"; do
        [[ -e $f ]] && return 0
    done
    echo "no packages found in $dir" >&2
    exit 1
}

require "$dist/arch-pkgs" "$dist"/arch-pkgs/podman-bcachefs-[0-9]*.pkg.tar.zst
require "$dist/noble-debs" "$dist"/noble-debs/podman_*.deb
require "$dist/resolute-debs" "$dist"/resolute-debs/podman_*.deb
require "$dist/trixie-debs" "$dist"/trixie-debs/podman_*.deb

cat <<EOF
bcachefs-enabled podman + containers/storage packages.

The driver is registered at compile time, so podman must be *recompiled* against the patched storage — installing a patched storage library alone does nothing. Each binary here was checked for the driver symbol by the pipeline that built it.

## Install

### Debian 13, Ubuntu 24.04, Ubuntu 26.04

\`\`\`bash
curl -fsSLO https://apt.ticpu.net/ticpu-archive-keyring.deb
sudo dpkg -i ticpu-archive-keyring.deb
sudo apt-get update
sudo apt-get install podman podman-docker
\`\`\`

The keyring package registers the suite matching your release and pins podman to the archive at priority 1001, so a later archive revision cannot replace it with a build that has no bcachefs driver. Earlier releases told you to \`apt-mark hold\`; that is no longer needed, and an existing hold can be dropped with \`sudo apt-mark unhold podman podman-docker\`.

### Arch Linux

\`\`\`bash
paru -S podman-bcachefs-bin
\`\`\`

\`podman-bcachefs\` provides/conflicts \`podman\`, so pacman will offer to replace an existing podman. Answer yes; the package name differs precisely so that a later \`pacman -Syu\` cannot silently swap the driver back out.

The package ships \`/etc/containers/storage.conf.d/00-storage-arch.conf\`, which sets \`driver_priority\`. That picks bcachefs for a graphroot with no prior driver directory — a store already carrying \`overlay/\` keeps overlay. Set \`driver = "bcachefs"\` in \`storage.conf\` to move an existing one.

## Point podman at bcachefs

On Debian and Ubuntu, in \`/etc/containers/storage.conf\`:

\`\`\`toml
[storage]
driver = "bcachefs"
graphroot = "/var/lib/containers/storage"
\`\`\`

The graphroot must be on a bcachefs filesystem; the driver refuses to initialize otherwise.

## Direct downloads

Every asset below is detach-signed; verify with \`gpg --verify <file>.asc <file>\` against key \`E5998E49DC9E1DCFDB9B46EC77EBA10790CFFCCD\`, or check \`SHA256SUMS\`. \`manifest.json\` names the suite each \`.deb\` was built for.

\`podman-remote\` and \`containers-storage\` are additional CLIs, not needed on a container host. \`golang-github-containers-storage-dev\` is build-time only — the driver is linked into podman itself, so installing it changes nothing at runtime.
EOF
