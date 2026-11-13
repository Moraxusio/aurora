import 'package:file_picker/file_picker.dart';
import 'package:aurora_profile/aurora_profile.dart';

import '../kernel/widgets.dart';
import '../state/app_state.dart';

Future<void> openLocalFolder(AppState app) async {
  try {
    final folder = await FilePicker.getDirectoryPath(dialogTitle: '打开本机项目文件夹');
    if (folder == null) return;
    final id = await app.useLocal();
    if (app.link(id) == null) {
      throw StateError(app.status(id).failure?.message ?? '本地 agent 未连接');
    }
    final location = app.localAgent.locate(folder);
    await app.update((p) {
      final s = p.server(id)!;
      var project = s.workspaces
          .where((w) => w.folders.length == 1 && w.folders.first == location)
          .firstOrNull;
      project ??= ProjectWorkspace(
        id: newId(),
        name: folder
            .replaceAll('\\', '/')
            .split('/')
            .where((x) => x.isNotEmpty)
            .last,
        folders: [location],
      );
      if (!s.workspaces.contains(project)) s.workspaces.add(project);
      s.selectedWorkspace = project.id;
      p.selected = id;
    });
  } on Object catch (e) {
    Toast.show(
      e is StateError ? e.message : '无法打开本机文件夹，请检查本地 agent 安装',
      error: true,
    );
  }
}
