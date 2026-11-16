package filetxn

import "os"

// Windows chmod exposes the writable attribute, not POSIX permission bits.
func modesEqual(a, b os.FileMode) bool { return a&0o200 == b&0o200 }

func ownership(os.FileInfo) (int, int)      { return -1, -1 }
func setOwnership(*os.File, int, int) error { return nil }

// Windows does not support fsync on a directory handle opened by os.Root.
func syncDirectory(*os.Root, string) error { return nil }
