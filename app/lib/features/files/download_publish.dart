import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _MoveFileNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _MoveFileDart = int Function(Pointer<Utf16>, Pointer<Utf16>);

/// The Windows package must not replace anything at the final path, even if
/// another program created that path after the download started. MoveFileW
/// without replacement publishes the same-volume staged file in one step.
Future<void> publishDownload(File staged, String destination) async {
  if (Platform.isWindows) {
    final source = _windowsPath(staged);
    final target = _windowsPath(File(destination));
    final moved = await Isolate.run(() => _moveWindows(source, target));
    if (moved) return;
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('目标文件已存在，请选择其它名称', destination);
    }
    throw FileSystemException('无法发布下载，请检查目标目录是否可写', destination);
  }
  // Other platforms retain their existing publish behavior; this native
  // no-clobber guarantee is specific to the Windows build.
  if (await FileSystemEntity.type(destination, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('目标文件已存在，请选择其它名称', destination);
  }
  await staged.rename(destination);
}

String _windowsPath(File file) {
  final path = file.absolute.path;
  if (path.startsWith(r'\\?\')) return path;
  final absolute = file.absolute.uri.normalizePath().toFilePath(windows: true);
  return absolute.startsWith(r'\\')
      ? '$_extended${r'UNC\'}${absolute.substring(2)}'
      : '$_extended$absolute';
}

const _extended = r'\\?\';

bool _moveWindows(String source, String target) {
  final move = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_MoveFileNative, _MoveFileDart>('MoveFileW');
  final from = source.toNativeUtf16();
  try {
    final to = target.toNativeUtf16();
    try {
      return move(from, to) != 0;
    } finally {
      malloc.free(to);
    }
  } finally {
    malloc.free(from);
  }
}
