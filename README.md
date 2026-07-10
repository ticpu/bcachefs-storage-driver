# bcachefs storage driver for containers/storage

A [containers/storage](https://github.com/containers/storage) graphdriver that
backs each image layer with a bcachefs **subvolume** and each child layer with a
CoW **snapshot** of its parent — the same model the `btrfs` driver uses.

Upstream PR: [containers/container-libs#518](https://github.com/containers/container-libs/pull/518)

## Why a driver at all

`overlay` works on bcachefs, but every layer is a full copy on disk and every
`podman build` rewrites them. With native subvolumes, a child layer is a
snapshot: creation is O(1), unchanged files share extents, and deleting an image
frees only what that layer actually added.

## What's here

```
driver/                       canonical driver (storage >= 1.59)
packaging/apply-driver.sh     overlays driver/ onto a storage source tree
packaging/arch/PKGBUILD       podman-bcachefs package
packaging/noble/              Ubuntu 24.04 (storage 1.51.0)
packaging/resolute/           Ubuntu 26.04 (storage 1.61.0)
scripts/test-snapshot-chain.sh   pure-CLI snapshot stress test (no Go)
```

The driver registers itself through `init()` in
`storage/drivers/register`, which `store.go` blank-imports. **Installing a
patched storage library is not enough — podman must be recompiled against it.**

## Supported targets

| Target | storage | Go module path | `SyncMode` |
| --- | --- | --- | --- |
| Ubuntu 24.04 (noble) | 1.51.0 | `github.com/containers/storage` | no |
| Ubuntu 26.04 (resolute) | 1.61.0 | `go.podman.io/storage` | no |
| Arch (podman 5.8.x) | 1.62.0 | `go.podman.io/storage` | no |
| container-libs `main` | 1.64.0-dev | `go.podman.io/storage` | yes |

storage renamed its module to `go.podman.io/storage` at 1.60, so
`apply-driver.sh --module` rewrites imports for the newer targets. Noble keeps
its own copy under `packaging/noble/driver/`: its `archive.FileInfo` has no
`target` field, so symlink-target collection cannot be backported there.

`SyncMode` is a *version* difference, not a fork difference. Storage 1.61/1.62
have no `SyncMode` type, so the driver must not define that method for those
targets.

## Building

Arch. The package is named `podman-bcachefs` and `provides`/`conflicts`
`podman`, so a later `pacman -Syu` can never quietly replace it with the
official build (which would drop the driver and strand your images):

```bash
cd packaging/arch && makepkg -sf
sudo pacman -U podman-bcachefs-*.pkg.tar.zst
```

Ubuntu. Build storage first, then podman against it — installing the `-dev` deb
alone does nothing, because registration happens at compile time. Substitute
`noble` for `resolute` on 24.04; keep the output directories separate, since the
podman build picks its `-dev` deb out of them by glob:

```bash
podman build -f packaging/resolute/Containerfile.storage -o out/resolute/ .
podman build -f packaging/resolute/Containerfile.podman  -o out/resolute/ .
sudo dpkg -i out/resolute/podman_*+bcachefs1_*.deb
```

On Debian/Ubuntu, `apt-mark hold podman podman-docker` afterwards. The
`+bcachefs1` suffix only outranks the archive while the base version matches; a
later archive revision sorts above it and an unheld upgrade silently installs an
unpatched podman, which then refuses to start against a `bcachefs` storage.conf.
To take a security update, rebuild the new version through the Containerfiles
(they re-derive from `apt-get source podman`) rather than unholding.

### Prebuilt packages

Tagged releases carry prebuilt `.deb` (Noble, Resolute) and `.pkg.tar.zst`
(Arch) packages with a `SHA256SUMS`, built and driver-verified by the same
pipeline that gates CI. Cutting one is a tag push:

```bash
git tag v5.7.0-bcachefs1 && git push --tags
```

Enable it in `/etc/containers/storage.conf`:

```toml
[storage]
driver = "bcachefs"
graphroot = "/var/lib/containers/storage"
```

The graphroot must be on a bcachefs filesystem; the driver refuses to
initialize otherwise.

## It works — here's the proof

Pull a multi-layer image into a bcachefs graphroot:

```console
$ podman --root /mnt/bcachefs/@podman/demo/root --storage-driver bcachefs \
       pull docker.io/library/nginx:alpine
$ podman --root /mnt/bcachefs/@podman/demo/root --storage-driver bcachefs \
       info --format '{{.Store.GraphDriverName}}'
bcachefs
```

Each layer is a snapshot of the one below it — a real CoW chain, not copies:

```console
$ bcachefs subvolume list -Rst /mnt/bcachefs
├── demo/root/bcachefs/subvolumes/31ad4a47… [2026-07-10 10:43]
├── demo/root/bcachefs/subvolumes/a8539d59… [snap of /@podman/demo/root/bcachefs/subvolumes/31ad4a47…]
├── demo/root/bcachefs/subvolumes/09c4f47f… [snap of /@podman/demo/root/bcachefs/subvolumes/a8539d59…]
├── demo/root/bcachefs/subvolumes/91c5c9d9… [snap of /@podman/demo/root/bcachefs/subvolumes/09c4f47f…]
├── demo/root/bcachefs/subvolumes/c87145b6… [snap of /@podman/demo/root/bcachefs/subvolumes/91c5c9d9…]
├── demo/root/bcachefs/subvolumes/b8cf3df0… [snap of /@podman/demo/root/bcachefs/subvolumes/c87145b6…]
├── demo/root/bcachefs/subvolumes/ab906055… [snap of /@podman/demo/root/bcachefs/subvolumes/b8cf3df0…]
├── demo/root/bcachefs/subvolumes/6311946b… [snap of /@podman/demo/root/bcachefs/subvolumes/ab906055…]
└── demo/root/bcachefs/subvolumes/c449f039… [snap of /@podman/demo/root/bcachefs/subvolumes/6311946b…]
```

(Subvolume IDs truncated; the base subvolume is the image's first layer and the
last snapshot is the running container's rootfs.) `podman rmi` unwinds the whole
chain — nested subvolumes are destroyed recursively, leaving nothing behind.

Verified working: multi-layer images (nginx, python, ceph:v18), CoW snapshots
preserving parent content through 50+ generations, recursive nested subvolume
deletion, root and rootless, and the full graphdriver lifecycle
(`Create` → `Get` → `ApplyDiff` → `Diff` → `Changes` → `Put`).

## Implementation notes

**COW-aware diff.** The stock `ChangesDirs` prunes subtrees whose inode numbers
match between the old and new layer. On a CoW filesystem a snapshot *shares*
inode numbers with its parent, so that pruning silently skips modified
subtrees. `changes_full.go` walks both trees completely, comparing symlink
targets and xattrs.

**Subvolume lifecycle** goes through `BCH_IOCTL_SUBVOLUME_CREATE` /
`_DESTROY` (`0x4020bc10` / `0x4020bc11`). The ioctl struct stores paths as raw
`uint64` pointers, invisible to Go's GC, so every call is followed by
`runtime.KeepAlive` on the path buffers.

**Driver detection** compares the statfs magic against
`BCACHEFS_SUPER_MAGIC` (`0xca451a4e`).

## Troubleshooting

**`driver not supported`** — podman was not recompiled against the patched
storage. To tell a *registered but unusable* driver from an unregistered one,
point podman at a fresh root: an unknown driver reports `driver not supported`,
while a registered one reports
`prerequisites for driver not satisfied (wrong filesystem?)`.

**`bcachefs subvolume list` prints paths that do not exist** — under a
*subdirectory* mount (`/dev/sdX[/@sub/dir]` mounted at `/var/lib/containers`)
the tool builds paths relative to the enclosing subvolume root rather than the
mount point, then joins that fragment onto the target, so it emits
`/var/lib/containers/dir/...` and fails to open it. Cosmetic, observed in
bcachefs-tools 1.38.8; the driver ioctls absolute paths and is unaffected.
Output is correct when the mount point coincides with the subvolume root.

**storage deb build segfaults in `TestStoreMultiList`** — only when built as
root. Debian's skip patch calls `err.Error()` on the `CreateContainer` result to
decide whether to skip; as root that call succeeds, `err` is nil, and the test
nil-derefs. Ubuntu buildds build unprivileged. Build as a non-root user rather
than disabling the test suite.

**Container exits immediately / missing `/bin/sh`** — SentinelOne kills sshd and
its children (including podman) mid-layer-apply, leaving partially extracted
subvolumes with missing files, and triggers a kernel WARNING at `cleanup_mnt`.
Disable it, `podman rmi` the broken image, re-pull.

## License

Apache-2.0, matching containers/storage, from which `bcachefs.go` (modeled on
`btrfs.go`) and `changes_full.go` derive.
