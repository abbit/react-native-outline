// See https://github.com/golang/go/wiki/Modules#how-can-i-track-tool-dependencies-for-a-module

//go:build tools
// +build tools

package tools

import (
	// Tool imports for mobile build.
	_ "golang.org/x/mobile/cmd/gomobile"
)
