# bcachefs storage driver for containers/storage

A containers/storage graphdriver backing each image layer with a bcachefs
subvolume and each child layer with a CoW snapshot of its parent, plus the
packaging that ships it for Arch, Ubuntu 24.04 (noble), Ubuntu 26.04 (resolute)
and Debian 13 (trixie).

Upstream PR: containers/container-libs#518.

## Layout

```
driver/                     canonical driver (storage >= 1.57)
driver/syncmode.go          SyncMode(), applied only to storage >= 1.63
driver/deferredremove.go    DeferredRemove(), applied only to storage >= 1.59
packaging/apply-driver.sh   overlays driver/ onto an unpacked storage tree
packaging/arch/             PKGBUILD + storage.conf.d drop-in
packaging/noble/            Containerfiles + a v1.51-specific driver copy
packaging/resolute/         Containerfiles only
packaging/trixie/           Containerfiles only
.github/release-notes.sh   generates release notes from the built artifacts
scripts/                   pure-CLI snapshot stress test (no Go)
```

`driver/` is the single source of truth. `apply-driver.sh` copies it into a
target tree, rewrites the import path, and patches `drivers/driver_linux.go`.
Noble is the one exception: its `archive.FileInfo` has no `target` field, so
symlink-target collection cannot be backported and it keeps its own copy under
`packaging/noble/driver/`. Everything else must not be forked — a per-distro
copy of the driver drifts and the drift only shows up as a silent wrong-answer
bug much later.

## Registration is compile-time

`store.go` blank-imports `drivers/register`, which pulls each driver's `init()`.
**Installing a patched storage library does nothing on its own — podman must be
recompiled against it.** Every packaging target therefore builds storage first,
then rebuilds podman against that storage. The `-dev` deb is build-time only.

CI asserts the symbol `storage/drivers/bcachefs.diffDriver.ApplyDiff` is present
in each built podman binary. That assertion is the thing that proves a package
actually carries the driver; keep it fail-closed (`grep -qaF "${VAR:?}"`, `-a`
because the target is a binary).

## Version matrix

| Target | storage | module path | `DeferredRemove` | `SyncMode` |
| --- | --- | --- | --- | --- |
| noble | 1.51.0 | `github.com/containers/storage` | no | no |
| trixie | 1.57.2 | `github.com/containers/storage` | no | no |
| resolute | 1.61.0 | `go.podman.io/storage` | yes | no |
| Arch (podman 6.0.x) | 1.63.0 | `go.podman.io/storage` | yes | yes |
| container-libs `main` | 1.64.0 | `go.podman.io/storage` | yes | yes |

storage renamed its module to `go.podman.io/storage` at 1.60, hence
`apply-driver.sh --module`.

Each `ProtoDriver` method whose types postdate the oldest target lives in its own
file, and `apply-driver.sh` greps the target's `drivers/driver.go` to decide
whether to install it: `SyncMode()` (the `SyncMode` type arrived in 1.63) and
`DeferredRemove()`/`GetTempDirRootDirs()` (`internal/tempdir` arrived in 1.59).
The target is the authority, so there is no per-distro flag to keep in sync, and
either mistake is a loud compile error (missing method → does not satisfy
`ProtoDriver`; stray method → undefined type or package).

Everything the driver stubs out is a no-op with the right shape: `Dedup()` →
empty `DedupResult`, `DeferredRemove()` → delegates to `Remove()`,
`GetTempDirRootDirs()` → empty slice. The interface keeps growing; a build
against every target is what catches the next one.

`driver/bcachefs_test.go` only builds against storage >= 1.62, where
`NaiveDiffDriver.ApplyDiff` lost its `parent` argument. Older targets are
compiled with `--strip-tests`, which is how the distro packages build anyway.

## Building

```bash
cd packaging/arch && makepkg -sf
podman build -f packaging/resolute/Containerfile.storage -o out/resolute/ .
podman build -f packaging/resolute/Containerfile.podman  -o out/resolute/ .
```

Substitute `noble` (24.04) or `trixie` (Debian 13) for `resolute`, and keep the
output directories separate — the podman build globs its `-dev` deb out of them.

Build the storage deb as a **non-root** user. Debian's
`TestStoreMultiList` skip patch calls `err.Error()` on the `CreateContainer`
result to decide whether to skip; as root that call succeeds, `err` is nil, and
the test nil-derefs. Ubuntu buildds build unprivileged and never hit it. Do not
reach for `DEB_BUILD_OPTIONS=nocheck` — the failure is unrelated to bcachefs and
the rest of the suite is worth keeping. The Containerfiles already `USER builder`.

Noble builds podman from the **`libpod`** source package; resolute and trixie
renamed it to `podman`. `apt-get source podman` resolves either, but the unpacked
directory differs — hence the `libpod-*` globs in the noble Containerfile.

Debian images carry `/etc/apt/sources.list.d/debian.sources`, Ubuntu's
`ubuntu.sources`; the `deb-src` `sed` names the file, so it is per-distro.

When bumping the Arch PKGBUILD, **re-derive it from the official
archlinux/packaging podman PKGBUILD** rather than editing in place. The official
file gains deps and functions between releases: 5.8.3 added a `check()` gating on
the system container-libs version, and 6.0.0 moved the upstream repo to
`podman-container-tools/podman` and swapped `iptables` for `nftables`.

## Arch: containers-common forces overlay

storage 1.63 replaced the config loader (`pkg/configfile`). The main config is
**first-match-only** across `~/.config` → `/etc` → `/usr/share`, and **drop-ins
are parsed after it and override it**. Arch's containers-common ships
`/usr/share/containers/storage.conf.d/00-storage-arch.conf` with
`driver = "overlay"`, so a *vendor drop-in* overrides an admin's
`driver = "bcachefs"` in `/etc/containers/storage.conf`, and a fresh graphroot
silently comes up overlay.

It cannot be fixed in config: an explicit driver short-circuits `driver_priority`
(`drivers/driver.go`: `if name != "" { return GetDriver(...) }`), and a later
drop-in cannot clear it because empty values are skipped
(`if config.Storage.Driver != ""`).

The PKGBUILD therefore ships `/etc/containers/storage.conf.d/00-storage-arch.conf`.
Drop-ins de-duplicate **by basename** with `/etc` outranking `/usr/share`, so
reusing the name *replaces* the vendor file rather than merging with it. Ours sets
only `driver_priority`, keeping an explicit `driver` in `storage.conf`
authoritative. `package_podman-bcachefs()` fails the build if any *other*
containers-common drop-in starts forcing a driver, since the shadow would no
longer cover it.

`driver_priority` selects, it does not migrate: `New()` runs `ScanPriorDrivers()`
first, and prior state wins, so a graphroot already carrying an `overlay/`
directory keeps overlay. Existing stores need an explicit `driver`.

Existing graphroots otherwise keep working because the database records the real
driver and overrides the config back — that is what `User-selected graph driver
"overlay" overwritten by ... from database` means. It is podman reporting that the
config lost.

## Debian/Ubuntu: hold the packages

`apt-mark hold podman podman-docker` after installing. The `+bcachefs1` suffix
only outranks the archive while the base version matches; a later archive revision
(`5.7.0+ds2-3build2` vs `...-3build1+bcachefs1`) sorts *above* it, and an unheld
upgrade silently installs an unpatched podman, which then refuses to start against
a `bcachefs` storage.conf. To take a security update, rebuild the new version
through the Containerfiles — they re-derive from `apt-get source podman` and pick
the new version up automatically. Never unhold and let apt install the archive
package.

## Checking upstream

Run this when asked whether the driver or the packages need an update. It is
read-only and needs no checkout of the distro trees.

1. **Interface drift.** Clone the newest `storage/v*` tag of
   `containers/container-libs` (`--filter=blob:none --sparse`, then
   `git sparse-checkout set storage common image` — the storage module's
   `go.work` names the two siblings and the build fails without them), apply the
   driver, `go build ./drivers/... ./pkg/archive/...` and `go vet
   ./drivers/bcachefs/...`. A new `ProtoDriver` method shows up here as a
   compile error naming the missing method. `gh api repos/containers/container-libs/tags`
   lists the tags.
2. **Anchor drift.** `apply-driver.sh` prints which optional files it installed
   and hard-errors if a `driver_linux.go` anchor stopped matching, so step 1
   covers it.
3. **`changes_full.go` drift.** It mirrors `walkchunk` in
   `pkg/archive/changes_linux.go`; upstream churn there is invisible to the
   compiler. Read both when upstream touches `pkg/archive`.
4. **Distro versions.** `curl -sS 'https://sources.debian.org/api/src/<pkg>/'`
   for Debian and Ubuntu source versions (`podman`,
   `golang-github-containers-storage`); `gh api repos/podman-container-tools/podman/releases/latest`
   for what Arch will pin next. Only Arch carries a version in this repo — the
   Containerfiles re-derive from `apt-get source` and need no bump.
5. **Upstream PR.** `gh pr view 518 --repo containers/container-libs`.

## Implementation notes

- `BCACHEFS_SUPER_MAGIC = 0xca451a4e`.
- `BCH_IOCTL_SUBVOLUME_CREATE` = `0x4020bc10`, `_DESTROY` = `0x4020bc11`. Flags:
  `1 << 0` snapshot, `1 << 1` read-only (unused).
- The ioctl struct stores paths as raw `uint64` pointers, invisible to Go's GC.
  Every call is followed by `runtime.KeepAlive` on the path buffers.
- **COW-aware diff.** Stock `ChangesDirs` prunes subtrees whose inode numbers
  match between layers. On a CoW filesystem a snapshot *shares* inode numbers with
  its parent, so that pruning silently skips modified subtrees. `changes_full.go`
  walks both trees completely, comparing symlink targets and xattrs.
- Reference implementation for the driver shape: `drivers/btrfs/btrfs.go`.

## Testing

```bash
BCACHEFS_TEST_ROOT=/path/on/bcachefs go test -v -run 'Subvolume|Chain' ./drivers/bcachefs/...
sudo BCACHEFS_TEST_ROOT=... go test -v -run TestGraph ./drivers/bcachefs/...
scripts/test-snapshot-chain.sh /path/on/bcachefs 50                          # no Go
```

The subvolume ioctls need no privileges; it is `Init()`'s `mount.MakePrivate` and
`chrootarchive` that make the `TestGraph*` set root-only. Hence the `-run` filter
on the first line — an unfiltered run picks those up and fails on the bind mount.
The shell stress test is pure bcachefs CLI: if it fails, it is a kernel bug, not
ours.

Tests only build against storage >= 1.62 (see the version matrix), so run them
from a tree at that level or newer.

## CI and releases

`ci.yml` and `release.yml` both call the reusable `build.yml` (lint, vet, noble,
resolute, trixie, arch). **A tag builds every distro, on purpose** — `driver/` and
`apply-driver.sh` are shared, so compiling every target is the only thing proving
a shared change did not break the ones you were not thinking about. That is what
catches API drift like `SyncMode`.

The vet job resolves the *newest* released storage tag at run time rather than
pinning one, so upstream API drift turns CI red on the next run instead of on the
next distro bump.

Cut a release with a signed tag; the workflow rebuilds, re-verifies the driver
symbol, and publishes the packages with a `SHA256SUMS`:

```bash
gh run watch "$(gh run list --branch main --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
git tag -s vX.Y.Z -F - <<'EOF'
...
EOF
git push --tags
```

**Never tag before main's own run is green.** A tag re-runs the same build, so a
break that main would have caught surfaces as a failed release instead — with the
tag already public. Tag messages carry a changelog for someone not following
development, hence the heredoc rather than `-m`.

Commits and tags are signed with the EC key on `jeromepoulin@gmail.com`, which is
neither the global git identity nor the default signing key here; `.git/config`
pins both. The hook that CLAUDE.md's repo conventions describe is **not installed
in every clone** — check the author and key on the tip before pushing rather than
trusting it to reject a wrong one.

Releases are versioned for **this repository**, not for podman — one release spans
every distro, each carrying a different podman version.

`.github/release-notes.sh` generates the notes from the artifact directories, so
the install snippets carry the exact filenames just built (package names embed
upstream versions and change every bump). It hard-errors if a platform yields no
packages: a release whose install script silently lists nothing is worse than a
failed build.

The Arch CI job passes `--nocheck`. The PKGBUILD's `check()` gates podman's
vendored container-libs against the *system* containers-common, which on a rolling
image legitimately drifts ahead of a pinned `pkgver` and says nothing about whether
the driver still applies and links. The gate is kept for local builders and the
skew is reported as a non-fatal warning rather than swallowed.

## Gotchas

- **`grep` here may be ugrep**, which rejects `^\+\+\+`, reads all of stdin (so it
  never SIGPIPEs), and skips binary files without `-a`. Two bugs came from this: a
  `| grep -q` in a pipeline under `pipefail` reported failure via upstream SIGPIPE,
  and a `grep -qF` on a binary silently matched nothing. Use `awk` for anchored
  matching, here-strings instead of `echo |`, and `-a` on binaries.
- `bcachefs subvolume list` prints paths that do not exist under a *subdirectory*
  mount: it builds paths relative to the enclosing subvolume root rather than the
  mount point. Cosmetic, seen in bcachefs-tools 1.38.8; the driver ioctls absolute
  paths and is unaffected.
- To tell a *registered but unusable* driver from an unregistered one, point podman
  at a fresh root: an unknown driver reports `driver not supported`, a registered
  one reports `prerequisites for driver not satisfied (wrong filesystem?)`.
- Container exits immediately / missing `/bin/sh`: an EDR agent killing podman
  mid-layer-apply leaves partially extracted subvolumes. Not a driver bug.

## Repo conventions

- Commits are signed and authored `jeromepoulin@gmail.com`. A pre-commit hook
  enforces the author, the signature, a scan for internal references, and
  `gitleaks git --staged`. `.gitleaks.toml` is deliberately **not committed** (a
  rule matching an internal name would itself leak it); it is excluded via
  `.git/info/exclude`.
- The upstream PR branch uses `Signed-off-by:` (DCO) and no `Co-Authored-By`, is a
  single squashed commit, and must be `gofumpt`-clean — not merely `gofmt`-clean.
- Apache-2.0, matching containers/storage, from which the driver derives.
