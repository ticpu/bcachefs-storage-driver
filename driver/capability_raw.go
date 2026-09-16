package archive

import "github.com/containers/storage/pkg/idtools"

// fullCapability for storage trees with no normalizeCapabilityRootID, which
// arrived in 1.64.1.
func fullCapability(_ *idtools.IDMappings, capData []byte) ([]byte, error) {
	return capData, nil
}
