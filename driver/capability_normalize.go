package archive

import "github.com/containers/storage/pkg/idtools"

// fullCapability rewrites the root ID inside a v3 security.capability xattr into
// the container ID space, so two layers mapped differently still compare equal.
func fullCapability(idMappings *idtools.IDMappings, capData []byte) ([]byte, error) {
	return normalizeCapabilityRootID(idMappings, capData)
}
