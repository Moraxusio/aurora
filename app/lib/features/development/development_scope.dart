import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/development/development_model.dart';
import '../../kernel/workspace.dart';

Future<DevelopmentScope?> selectDevelopmentScope(
  BuildContext context,
  Workspace ws,
) async {
  final folder = await selectWorkspaceFolder(context, ws);
  if (folder == null) return null;
  return ws.development.configuration(folder.root, folder.path, refresh: true);
}

Future<WorkspacePath?> selectWorkspaceFolder(
  BuildContext context,
  Workspace ws,
) async {
  final folders = ws.project?.folders ?? <WorkspacePath>[];
  final current = ws.active?.file;
  WorkspacePath? folder;
  if (current != null) {
    final doc = ws.documents.find(current.root, current.path);
    folder = doc == null
        ? WorkspacePath(root: current.root, path: '/')
        : ws.development.scopeFor(doc);
  }
  if (folder == null && folders.length > 1) {
    folder = await showWorkbenchDialog<WorkspacePath>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('选择项目文件夹'),
        content: SizedBox(
          width: 600,
          height: 280,
          child: ListView.builder(
            itemCount: folders.length,
            itemBuilder: (_, i) => TreeRow(
              label: folders[i].path,
              subtitle: folders[i].root,
              onTap: () => Navigator.pop(c, folders[i]),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  } else {
    folder ??= folders.firstOrNull;
  }
  if (folder == null) {
    ws.toast('请先打开项目文件夹或文件');
    return null;
  }
  return folder;
}
