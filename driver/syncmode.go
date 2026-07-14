//go:build linux

package bcachefs

import graphdriver "github.com/containers/storage/drivers"

// SyncMode returns the sync mode configured for the driver.
//
// Kept out of bcachefs.go: graphdriver.SyncMode only exists from storage 1.63
// on, and ProtoDriver only requires this method from that version. apply-driver.sh
// installs this file only when the target tree declares the type.
func (d *Driver) SyncMode() graphdriver.SyncMode {
	return graphdriver.SyncModeNone
}
