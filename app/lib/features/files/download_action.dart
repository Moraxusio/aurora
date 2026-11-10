// Download one remote file into a folder the user picks. Shared by the file
// tree and by the viewers (the "download" button of an image or a PDF).
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';

/// False when there is nothing to download with (no link, or the file tree
/// has not been shown yet, so no transfer list exists).
bool canDownload(Workspace ws) => ws.link != null && ws.transfers != null;

Future<void> downloadRemoteFile(Workspace ws, {required String root, required String path, int size = 0}) async {
  final link = ws.link;
  final transfers = ws.transfers;
  if (link == null || transfers == null) return;
  final name = path.split('/').last;
  final dir = await FilePicker.getDirectoryPath(dialogTitle: '下载 $name 到…');
  if (dir == null) return;
  var where = '$dir${Platform.pathSeparator}$name';
  for (var i = 1; await File(where).exists(); i++) {
    final dot = name.lastIndexOf('.');
    where = dot > 0 ? '$dir${Platform.pathSeparator}${name.substring(0, dot)} ($i)${name.substring(dot)}' : '$dir${Platform.pathSeparator}$name ($i)';
  }
  transfers.download(link, root, path, where, size, onDone: () => Toast.show('已下载 $name'));
}
