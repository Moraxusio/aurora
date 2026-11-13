import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'ai_models.dart';

const aiAttachmentLimit = 8 * 1024 * 1024;
const aiAttachmentTotalLimit = 20 * 1024 * 1024;
const _inputChannel = MethodChannel('aurora3/input');

String aiAttachmentMime(Uint8List bytes) {
  bool start(List<int> magic) =>
      bytes.length >= magic.length && List.generate(magic.length, (i) => bytes[i] == magic[i]).every((v) => v);
  if (start([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
  if (start([255, 216, 255])) return 'image/jpeg';
  if (start([71, 73, 70, 56])) return 'image/gif';
  if (bytes.length > 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image/webp';
  }
  if (start([37, 80, 68, 70, 45])) return 'application/pdf';
  if (bytes.contains(0)) throw StateError('不支持此二进制文件；请选择图片、PDF、UTF-8 文本或代码');
  try {
    utf8.decode(bytes);
  } on FormatException {
    throw StateError('文本不是 UTF-8 编码，请转换编码后再添加');
  }
  if (bytes.length > 256 * 1024) throw StateError('文本文件不能超过 256 KiB');
  return 'text/plain';
}

AiAttachment aiAttachmentFromBytes(String name, Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > aiAttachmentLimit) throw StateError('单个附件应为 1 字节至 8 MiB');
  final clean = name.replaceAll('\\', '/').split('/').last;
  validateAiAttachmentName(clean);
  final mime = aiAttachmentMime(bytes);
  return AiAttachment(
    kind: mime.startsWith('image/') ? 'image' : 'file',
    label: clean,
    content: '',
    bytes: bytes,
    mime: mime,
  );
}

void validateAiAttachmentName(String name) {
  final clean = name.replaceAll('\\', '/').split('/').last;
  if (RegExp(
    r'(^id_(rsa|ed25519|ecdsa)$|\.(key|pem|p12|pfx|jks)$|^profile\.bin$)',
    caseSensitive: false,
  ).hasMatch(clean)) {
    throw StateError('为避免泄露凭据，不支持直接附加私钥、密钥库或加密配置文件');
  }
}

Future<Uint8List> _bounded(Stream<List<int>> source) async {
  final out = BytesBuilder(copy: false);
  await for (final b in source) {
    if (out.length + b.length > aiAttachmentLimit) throw StateError('单个附件不能超过 8 MiB');
    out.add(b);
  }
  return out.takeBytes();
}

Future<List<AiAttachment>> pickAiLocalFiles() async {
  final result = await FilePicker.pickFiles(dialogTitle: '选择 AI 对话附件（图片 / PDF / 文本）');
  if (result.length > 8) throw StateError('每次最多选择 8 个附件');
  final files = <AiAttachment>[];
  for (final file in result) {
    validateAiAttachmentName(file.name);
    if ((await file.length() ?? 0) > aiAttachmentLimit) throw StateError('${file.name} 超过 8 MiB');
    final bytes = await _bounded(file.readAsByteStream());
    files.add(aiAttachmentFromBytes(file.name, bytes));
  }
  return files;
}

Future<List<AiAttachment>> readAiClipboardFiles() async {
  Map? result;
  try {
    result = await _inputChannel.invokeMapMethod('readClipboard');
  } on MissingPluginException {
    return [];
  }
  if (result == null) return [];
  final files = <AiAttachment>[];
  for (final path in result['paths'] as List? ?? []) {
    validateAiAttachmentName(path as String);
    final file = File(path);
    if (!await file.exists()) throw StateError('不支持粘贴目录或无法读取该文件，请选择单个文件');
    if (await file.length() > aiAttachmentLimit) throw StateError('单个附件不能超过 8 MiB');
    files.add(aiAttachmentFromBytes(file.uri.pathSegments.last, await _bounded(file.openRead())));
  }
  if (result['bytes'] is Uint8List) {
    files.add(aiAttachmentFromBytes(result['name'] as String? ?? 'clipboard.png', result['bytes'] as Uint8List));
  }
  for (final entry in result['files'] as List? ?? []) {
    final item = entry as Map;
    files.add(aiAttachmentFromBytes(item['name'] as String, item['bytes'] as Uint8List));
  }
  return files;
}

Future<List<AiAttachment>> readAiContentUri(String uri) async {
  final r = await _inputChannel.invokeMapMethod('readContentUri', {'uri': uri});
  return [
    for (final entry in r?['files'] as List? ?? [])
      aiAttachmentFromBytes((entry as Map)['name'] as String, entry['bytes'] as Uint8List),
  ];
}

Future<Map<String, dynamic>> uploadAiAttachment(
  Link link,
  AiAttachment attachment, {
  required bool Function() active,
  void Function(double)? progress,
}) async {
  final bytes = attachment.bytes!;
  final stream = await link.open('ai.attach.upload', {'name': attachment.label, 'size': bytes.length}, Priority.bulk);
  try {
    await stream.response();
    for (var off = 0; off < bytes.length; off += 65536) {
      if (!active()) throw StateError('附件上传已取消或服务器连接已变化');
      final end = (off + 65536).clamp(0, bytes.length);
      await stream.sendData(Uint8List.sublistView(bytes, off, end));
      progress?.call(end / bytes.length);
    }
    await stream.sendEnd();
    final result = await stream.response() as Map;
    if (result['id'] is! String) throw StateError('附件上传响应无效');
    return {'kind': attachment.kind, 'label': attachment.label, 'attachment_id': result['id']};
  } finally {
    stream.reset();
  }
}

Future<Uint8List> downloadAiAttachment(Link link, String id) async {
  final s = await link.open('ai.attach.download', {'id': id}, Priority.bulk);
  try {
    final meta = await s.response() as Map;
    if (meta['size'] is! num || (meta['size'] as num) > aiAttachmentLimit) throw StateError('附件大小无效');
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final f = await s.read();
      if (f == null) throw StateError('附件下载中断');
      if (f.isEnd) break;
      if (!f.isData) throw StateError('附件响应无效');
      if (bytes.length + f.payload.length > aiAttachmentLimit) throw StateError('附件过大');
      bytes.add(f.payload);
    }
    if (bytes.length != (meta['size'] as num).toInt()) throw StateError('附件下载不完整');
    return bytes.takeBytes();
  } finally {
    s.reset();
  }
}

Future<AiAttachment> readAiRemoteFile(Link link, String root, String path) async {
  validateAiAttachmentName(path);
  final s = await link.open('fs.download', {'root': root, 'path': path}, Priority.bulk);
  try {
    final meta = await s.response() as Map;
    final size = (meta['size'] as num?)?.toInt() ?? -1;
    if (size < 1 || size > aiAttachmentLimit) throw StateError('服务器文件应为 1 字节至 8 MiB');
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final f = await s.read();
      if (f == null) throw StateError('文件下载中断');
      if (f.isEnd) break;
      if (!f.isData || bytes.length + f.payload.length > size) throw StateError('文件数据无效或已变化');
      bytes.add(f.payload);
    }
    if (bytes.length != size) throw StateError('文件下载不完整');
    return aiAttachmentFromBytes(meta['name'] as String? ?? path.split('/').last, bytes.takeBytes());
  } finally {
    s.reset();
  }
}
