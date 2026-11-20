package statecrypt

import (
	"bytes"
	"errors"
	"unsafe"

	"golang.org/x/sys/windows"
)

const windowsKeyHeader = "AURORA-STATE-DPAPI\x01"

// WrapKey stores only a current-user DPAPI envelope, never the raw state key.
// Component-specific entropy keeps these envelopes distinct from those for
// agent identities and local service options.
func WrapKey(key []byte) ([]byte, error) {
	return WrapKeyFor(key, "")
}

func WrapKeyFor(key []byte, owner string) ([]byte, error) {
	if len(key) != KeyBytes {
		return nil, errors.New("invalid state key length")
	}
	b, err := UserDPAPI(key, []byte(windowsKeyHeader+owner), true)
	if err != nil {
		return nil, err
	}
	return append([]byte(windowsKeyHeader), b...), nil
}

func UnwrapKey(record []byte) (*Codec, error) {
	return UnwrapKeyFor(record, "")
}

func UnwrapKeyFor(record []byte, owner string) (*Codec, error) {
	if !bytes.HasPrefix(record, []byte(windowsKeyHeader)) {
		return nil, errors.New("state key is not a DPAPI envelope")
	}
	key, err := UserDPAPI(record[len(windowsKeyHeader):], []byte(windowsKeyHeader+owner), false)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	return New(key)
}

// UserDPAPI never uses CRYPTPROTECT_LOCAL_MACHINE or presents system UI.
func UserDPAPI(data, entropy []byte, seal bool) ([]byte, error) {
	if len(data) == 0 || len(data) > 64<<20 || len(entropy) == 0 {
		return nil, errors.New("受保护数据长度或类型无效")
	}
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	extra := windows.DataBlob{Size: uint32(len(entropy)), Data: &entropy[0]}
	var out windows.DataBlob
	const noUI = 1
	var err error
	if seal {
		err = windows.CryptProtectData(&in, nil, &extra, 0, nil, noUI, &out)
	} else {
		err = windows.CryptUnprotectData(&in, nil, &extra, 0, nil, noUI, &out)
	}
	if err != nil {
		return nil, err
	}
	if out.Data == nil {
		return nil, errors.New("DPAPI 未返回数据")
	}
	defer windows.LocalFree(windows.Handle(uintptr(unsafe.Pointer(out.Data))))
	tmp := unsafe.Slice(out.Data, out.Size)
	defer clear(tmp)
	return bytes.Clone(tmp), nil
}
