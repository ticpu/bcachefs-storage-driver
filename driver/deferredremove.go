//go:build linux

package bcachefs

import "github.com/containers/storage/internal/tempdir"

// DeferredRemove removes the layer immediately; nothing is deferred.
//
// Kept out of bcachefs.go: internal/tempdir only exists from storage 1.59 on,
// and ProtoDriver only requires these methods from that version. apply-driver.sh
// installs this file only when the target tree declares them.
func (d *Driver) DeferredRemove(id string) (tempdir.CleanupTempDirFunc, error) {
	return nil, d.Remove(id)
}

// GetTempDirRootDirs is not implemented.
func (d *Driver) GetTempDirRootDirs() []string {
	return []string{}
}
