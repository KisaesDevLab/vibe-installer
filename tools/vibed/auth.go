// Copyright 2026 Kisaes LLC
// Licensed under the PolyForm Internal Use License 1.0.0.

package main

import (
	"fmt"
	"os/user"
	"strconv"
)

// lookupGid returns the numeric gid for a system group name. Wraps
// os/user.LookupGroup with an int conversion so the caller doesn't
// need to ParseInt at every call site.
func lookupGid(name string) (int, error) {
	g, err := user.LookupGroup(name)
	if err != nil {
		return -1, fmt.Errorf("lookup group %q: %w", name, err)
	}
	gid, err := strconv.Atoi(g.Gid)
	if err != nil {
		return -1, fmt.Errorf("parse gid %q for group %q: %w", g.Gid, name, err)
	}
	return gid, nil
}
