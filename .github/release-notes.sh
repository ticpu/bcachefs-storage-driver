#!/bin/bash
set -euo pipefail

# Generate release notes with the exact filenames of the packages that were just
# built. Names carry upstream versions and change every bump, so they are read
# back out of the artifact directories rather than hand-maintained.
#
# Usage: release-notes.sh <tag> <owner/repo> <dist-dir> > NOTES.md
#
# <dist-dir> holds one subdirectory per upload-artifact name: arch-pkgs/,
# noble-debs/, resolute-debs/.

[[ $# -eq 3 ]] || { echo "usage: release-notes.sh <tag> <owner/repo> <dist-dir>" >&2; exit 2; }

tag="$1"
repo="$2"
dist="$3"
base="https://github.com/$repo/releases/download/$tag"

# Print the basenames matching a glob, one per line. Errors out rather than
# emitting nothing: a release whose install script silently lists no packages is
# worse than a failed build.
pick() {
    local dir="$1" desc="$2"
    shift 2
    local found=() f
    for f in "$@"; do
        [[ -e $f ]] && found+=("$(basename "$f")")
    done
    if [[ ${#found[@]} -eq 0 ]]; then
        echo "no $desc packages found in $dir" >&2
        exit 1
    fi
    printf '%s\n' "${found[@]}" | sort
}

# The version glob keeps podman-bcachefs-debug out of the install list.
mapfile -t arch < <(pick "$dist/arch-pkgs" arch \
    "$dist"/arch-pkgs/podman-bcachefs-[0-9]*.pkg.tar.zst \
    "$dist"/arch-pkgs/podman-docker-bcachefs-[0-9]*.pkg.tar.zst)

# podman-remote and containers-storage are extra CLIs, and the -dev deb is
# build-time only -- the driver is linked into podman itself. Install just what
# a container host needs.
mapfile -t noble < <(pick "$dist/noble-debs" noble \
    "$dist"/noble-debs/podman_*.deb "$dist"/noble-debs/podman-docker_*.deb)
mapfile -t resolute < <(pick "$dist/resolute-debs" resolute \
    "$dist"/resolute-debs/podman_*.deb "$dist"/resolute-debs/podman-docker_*.deb)

curl_lines() {
    local f
    for f in "$@"; do
        printf 'curl -fLO %s/%s\n' "$base" "$f"
    done
}

# "./a.deb ./b.deb" with no trailing space.
local_paths() {
    local joined
    joined="$(printf './%s ' "$@")"
    echo "${joined% }"
}

deb_section() {
    local name="$1"
    shift
    cat <<EOF
### $name

\`\`\`bash
$(curl_lines SHA256SUMS "$@")

sha256sum --ignore-missing -c SHA256SUMS
sudo dpkg -i $(local_paths "$@")
sudo apt-get -f install
sudo apt-mark hold podman podman-docker
\`\`\`
EOF
}

cat <<EOF
bcachefs-enabled podman + containers/storage packages.

The bcachefs driver is registered at compile time, so podman must be *recompiled*
against the patched storage — installing a patched storage library alone does
nothing. These packages are already built that way, and every one of them had its
bcachefs driver symbol verified by the same pipeline that gates CI.

Each snippet below downloads only the packages for that platform, checks them
against \`SHA256SUMS\`, and installs them. \`sha256sum --ignore-missing -c\` verifies
the files you actually downloaded and ignores the rest of the release.

## Install

### Arch Linux

\`podman-bcachefs\` provides/conflicts \`podman\`, so pacman will offer to replace an
existing podman. Answer yes; the package name differs precisely so that a later
\`pacman -Syu\` cannot silently swap the driver back out.

\`\`\`bash
$(curl_lines SHA256SUMS "${arch[@]}")

sha256sum --ignore-missing -c SHA256SUMS
sudo pacman -U $(local_paths "${arch[@]}")
\`\`\`

The package ships \`/etc/containers/storage.conf.d/00-storage-arch.conf\`, which sets
\`driver_priority\`. That picks bcachefs for a graphroot with no prior driver
directory — a store already carrying \`overlay/\` keeps overlay. Set
\`driver = "bcachefs"\` in \`storage.conf\` to move an existing one.

$(deb_section 'Ubuntu 24.04 (Noble)' "${noble[@]}")

$(deb_section 'Ubuntu 26.04 (Resolute)' "${resolute[@]}")

The \`apt-mark hold\` is not optional. A later archive revision sorts *above* our
\`+bcachefs1\` suffix, so an unheld upgrade silently installs an unpatched podman,
which then refuses to start against a \`bcachefs\` storage.conf. To take a security
update, rebuild the new version from the repository's Containerfiles instead of
unholding.

On Ubuntu, point podman at bcachefs in \`/etc/containers/storage.conf\`:

\`\`\`toml
[storage]
driver = "bcachefs"
graphroot = "/var/lib/containers/storage"
\`\`\`

The graphroot must be on a bcachefs filesystem; the driver refuses to initialize
otherwise.

## Optional extras

\`podman-remote\` and \`containers-storage\` are additional CLIs, not needed on a
container host. \`golang-github-containers-storage-dev\` is build-time only — the
driver is linked into podman itself, so installing it changes nothing at runtime.
EOF
