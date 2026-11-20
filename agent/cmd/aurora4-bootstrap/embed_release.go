//go:build aurora_bundle && windows

package main

import _ "embed"

//go:embed payload/runtime.zip
var payloadBytes []byte

//go:embed payload/manifest.json
var manifestBytes []byte

//go:embed payload/manifest.sig
var signatureBytes []byte
