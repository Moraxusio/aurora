// Builds the native TLS engine (src/aurora_tls.c on BoringSSL) for the target
// of each Dart or Flutter build. No Flutter engine change is needed.
//
// BoringSSL is C++ with hand-written assembly for AES-GCM, ChaCha20, SHA and
// the elliptic curves. The hook compiles it as three static libraries:
//   bcm + crypto  (C++)          libcrypto, incl. the FIPS-module sources
//   ssl           (C++)
//   asm           (per target)   .S through the C compiler, or .asm through
//                                NASM on Windows x64
// and links them with aurora_tls.c into one shared library. The source lists
// come from third_party/boringssl/gen/sources.json, which BoringSSL publishes
// for builds outside its own CMake.
//
// Windows x64 needs NASM 3.02: set AURORA_NASM to nasm.exe, or put it on PATH.
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const boringsslVersion = '0.20261020.0';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS;
    final arch = code.targetArchitecture;
    final pkg = input.packageRoot;
    const bssl = 'third_party/boringssl';
    final sources = jsonDecode(File.fromUri(pkg.resolve('$bssl/gen/sources.json')).readAsStringSync())
        as Map<String, dynamic>;
    List<String> list(String lib, String key) =>
        [for (final f in (sources[lib][key] as List? ?? const [])) '$bssl/$f'];

    // How the target gets its assembly: NASM on Windows x64, the C compiler
    // for .S elsewhere, none for targets BoringSSL has no assembly for.
    final asmTag = switch ((os, arch)) {
      (OS.windows, Architecture.x64) => 'nasm',
      (OS.windows, Architecture.arm64) => 'cc',
      (OS.linux || OS.android || OS.macOS || OS.iOS, Architecture.x64 || Architecture.arm64) => 'cc',
      _ => null,
    };

    final defines = <String, String?>{
      'BORINGSSL_IMPLEMENTATION': null,
      if (os == OS.windows) ...{
        '_HAS_EXCEPTIONS': '0',
        'WIN32_LEAN_AND_MEAN': null,
        'NOMINMAX': null,
        '_CRT_SECURE_NO_WARNINGS': null,
      },
      if (os == OS.linux) '_XOPEN_SOURCE': '700',
      if (asmTag == null) 'OPENSSL_NO_ASM': null,
    };
    final includes = ['$bssl/include'];
    final cxxFlags = [
      if (os == OS.windows) ...['/std:c++17', '/utf-8', '/Zc:__cplusplus', '/EHs-c-', '/GR-']
      else ...['-std=c++17', '-fno-exceptions', '-fno-rtti', '-fvisibility=hidden', '-fno-strict-aliasing', '-fno-common'],
    ];

    final outDir = input.outputDirectory;
    final libs = <String>[];

    Future<void> staticLib(String name, List<String> srcs, Language lang, {List<String> flags = const []}) async {
      if (srcs.isEmpty) return;
      final b = CBuilder.library(
        name: name,
        assetName: 'unused_$name',
        sources: srcs,
        includes: includes,
        defines: defines,
        flags: [...flags],
        language: lang,
        optimizationLevel: OptimizationLevel.o2,
      );
      await b.run(input: input, output: output, linkModePreference: LinkModePreference.static, routing: const []);
      libs.add(name);
    }

    // Link order matters for GNU ld and lld (each archive only satisfies
    // symbols needed by what comes before it): ssl, then crypto, then asm.
    await staticLib('bssl_ssl', list('ssl', 'srcs'), Language.cpp, flags: cxxFlags);
    await staticLib('bssl_crypto', [...list('bcm', 'srcs'), ...list('crypto', 'srcs')], Language.cpp, flags: cxxFlags);

    if (asmTag == 'nasm') {
      final nasm = await _findNasm();
      // Every file is assembled: each one guards itself with
      // %ifidn __OUTPUT_FORMAT__, so the 32-bit ones assemble to nothing
      // (BoringSSL's own CMake does the same).
      final asmSrcs = [...list('bcm', 'nasm'), ...list('crypto', 'nasm')];
      final objs = <String>[];
      final objDir = Directory.fromUri(outDir.resolve('nasm/'))..createSync(recursive: true);
      for (final s in asmSrcs) {
        final obj = '${objDir.path}${Platform.pathSeparator}${s.split('/').last.replaceAll('.asm', '.obj')}';
        final r = await Process.run(nasm, [
          '-fwin64', '-gcv8',
          '-I${pkg.resolve('$bssl/gen/').toFilePath()}',
          '-o', obj,
          pkg.resolve(s).toFilePath(),
        ]);
        if (r.exitCode != 0) throw Exception('nasm $s: ${r.stderr}');
        objs.add(obj);
      }
      // Archive with lib.exe from the same MSVC that the C builder uses.
      final libExe = await _msvcLib(input);
      final r = await Process.run(libExe.$1, ['/nologo', '/out:${outDir.resolve('bssl_asm.lib').toFilePath()}', ...objs],
          environment: libExe.$2);
      if (r.exitCode != 0) throw Exception('lib.exe: ${r.stdout}${r.stderr}');
      libs.add('bssl_asm');
    } else if (asmTag != null) {
      // Every .S is compiled: each guards itself with #if on the target
      // (OPENSSL_X86_64 / OPENSSL_AARCH64, __ELF__ / __APPLE__ / _WIN32), as
      // in BoringSSL's own CMake.
      final asmSrcs = [...list('bcm', 'asm'), ...list('crypto', 'asm')];
      await staticLib('bssl_asm', asmSrcs, Language.c);
    }

    final engine = CBuilder.library(
      name: 'aurora_tls',
      assetName: 'src/bindings.dart',
      sources: ['src/aurora_tls.c'],
      includes: ['src', ...includes],
      defines: {'AT_BORINGSSL_VERSION': '"$boringsslVersion"'},
      libraries: [
        ...libs,
        if (os == OS.windows) ...['advapi32', 'ws2_32'],
        if (os == OS.android) 'log',
        // native_toolchain_c puts the C++ runtime (cppLinkStdLib) before the
        // archives on the command line, where GNU ld drops it as unused; it
        // must come after them.
        if (os == OS.linux) 'stdc++',
      ],
      libraryDirectories: [outDir.toFilePath()],
      // aurora_tls.c is C, but BoringSSL is C++ and needs a few C++ runtime
      // symbols (operator delete, std::__throw_out_of_range_fmt). Linking as
      // C++ adds the runtime: libstdc++ on Linux (the Flutter Linux runner
      // links it too), the NDK's static libc++ on Android, MSVC's CRT on
      // Windows (always linked).
      language: os == OS.windows ? Language.c : Language.cpp,
      cppLinkStdLib: switch (os) {
        OS.android => 'c++_static',
        OS.linux => 'stdc++',
        _ => null,
      },
      optimizationLevel: OptimizationLevel.o2,
    );
    await engine.run(input: input, output: output);
  });
}

Future<String> _findNasm() async {
  final env = Platform.environment['AURORA_NASM'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
  for (final dir in (Platform.environment['PATH'] ?? '').split(';')) {
    final f = File('$dir\\nasm.exe');
    if (f.existsSync()) return f.path;
  }
  const fallback = r'nasm';
  if (File(fallback).existsSync()) return fallback;
  throw Exception('NASM not found: set AURORA_NASM to nasm.exe (NASM 3.02)');
}

/// lib.exe of the MSVC that builds for x64: it sits next to cl.exe in
/// VC\Tools\MSVC\<version>\bin\Hostx64\x64 (the newest version is used, as
/// native_toolchain_c does for cl.exe). lib.exe needs no environment.
Future<(String, Map<String, String>?)> _msvcLib(BuildInput input) async {
  const vswhere = r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';
  final r = await Process.run(vswhere, ['-latest', '-products', '*', '-property', 'installationPath']);
  final vs = (r.stdout as String).trim();
  final tools = Directory('$vs\\VC\\Tools\\MSVC');
  if (vs.isEmpty || !tools.existsSync()) throw Exception('MSVC not found (vswhere: "$vs")');
  final versions = tools.listSync().whereType<Directory>().map((d) => d.path).toList()..sort();
  for (final v in versions.reversed) {
    final f = File('$v\\bin\\Hostx64\\x64\\lib.exe');
    if (f.existsSync()) return (f.path, null);
  }
  throw Exception('lib.exe not found under ${tools.path}');
}
