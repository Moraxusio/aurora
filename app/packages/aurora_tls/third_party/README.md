# Third-party code in aurora_tls

## BoringSSL 0.20261020.0

- Source: <https://github.com/google/boringssl/releases/tag/0.20261020.0>
- Archive: `boringssl-0.20261020.0.tar.gz`, SHA-256
  `fb43aac7fbd323c9dfa1f45fe92a1c01142433c05b23fe34f61d6ba8b13b642e`
  (the value GitHub publishes for the release asset).
- License: Apache-2.0 (`boringssl/LICENSE`).
- Contents: the files that `gen/sources.json` lists for the `bcm`, `crypto` and
  `ssl` libraries, plus `include/openssl` (without `include/openssl/pki`, which
  the libraries do not use). Every file is byte-identical to the release; none
  is modified. `../hook/build.dart` compiles them.

To update: unpack the new release, copy the same set of files, set
`boringsslVersion` in `hook/build.dart`, and record the new SHA-256 here.

## Build tool: NASM 3.02 (Windows x64 only)

BoringSSL's x86-64 assembly for Windows is in NASM syntax. The hook runs
`nasm.exe`; it is not part of the repository or the app.

- Source: <https://www.nasm.us/pub/nasm/releasebuilds/3.02/win64/>
- `nasm-3.02-installer-x64.exe`, SHA-256
  `0ddb40310861eb29f4d649feb9466779982a2d251c0db2b9cf0d21cf591171f3`, matches
  the winget manifest `NASM.NASM` 3.02. `nasm.exe` from
  `nasm-3.02-win64.zip` (SHA-256
  `161d0bfaff53c2f9e9f3e69fd0672323ebabafd1268976a5cec11be92a19aee7`) is
  byte-identical to the one that installer installs (SHA-256
  `04ec2385879f7e1c45dbe76c4020970555de48eeb97c23f59620ede061328f51`).
- License: BSD-2-Clause.
- Location on the build machine: `<nasm-dir>`, or set
  `AURORA_NASM` to `nasm.exe`.
