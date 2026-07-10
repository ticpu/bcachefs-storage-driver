//go:build linux

package bcachefs

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBcachefsSubvolumeOperations(t *testing.T) {
	testRoot := os.Getenv("BCACHEFS_TEST_ROOT")
	if testRoot == "" {
		t.Skip("BCACHEFS_TEST_ROOT not set, skipping bcachefs tests")
	}

	testDir := filepath.Join(testRoot, "test-subvol")

	t.Run("CreateSubvolume", func(t *testing.T) {
		err := subvolCreate(testDir)
		if err != nil {
			t.Fatalf("Failed to create subvolume: %v", err)
		}

		if _, err := os.Stat(testDir); os.IsNotExist(err) {
			t.Fatal("Subvolume directory does not exist after creation")
		}
	})

	t.Run("CreateSnapshot", func(t *testing.T) {
		snapshotDir := filepath.Join(testRoot, "test-snapshot")
		err := subvolSnapshot(testDir, snapshotDir)
		if err != nil {
			t.Fatalf("Failed to create snapshot: %v", err)
		}

		if _, err := os.Stat(snapshotDir); os.IsNotExist(err) {
			t.Fatal("Snapshot directory does not exist after creation")
		}

		err = subvolDelete(testRoot, "test-snapshot")
		if err != nil {
			t.Fatalf("Failed to delete snapshot: %v", err)
		}
	})

	t.Run("DeleteSubvolume", func(t *testing.T) {
		err := subvolDelete(testRoot, "test-subvol")
		if err != nil {
			t.Fatalf("Failed to delete subvolume: %v", err)
		}

		if _, err := os.Stat(testDir); !os.IsNotExist(err) {
			t.Fatal("Subvolume directory still exists after deletion")
		}
	})
}
