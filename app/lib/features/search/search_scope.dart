// Where search and quick open look: the folders of the project in front, or,
// while browsing the whole server, every root except the system root "/"
// (searching all of / is slow and finds mostly noise; the user can still add
// "/" as a project folder to search it on purpose).
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';

import '../../kernel/workspace.dart';

class SearchFolder {
  final String root;
  final String path;
  final String label;
  const SearchFolder(this.root, this.path, this.label);
  @override
  bool operator ==(Object other) => other is SearchFolder && other.root == root && other.path == path;
  @override
  int get hashCode => Object.hash(root, path);
}

/// The folders to search for [ws], or none when not connected.
Future<List<SearchFolder>> searchFolders(Workspace ws) async {
  final link = ws.link;
  if (link == null) return const [];
  final project = ws.project;
  if (project != null) {
    return [for (final f in project.folders) SearchFolder(f.root, f.path, f.path == '/' ? f.root : f.name)];
  }
  try {
    final r = await link.call('fs.roots') as Map;
    return [
      for (final x in (r['roots'] as List).cast<Map>())
        if (x['ok'] != false && x['path'] != '/')
          SearchFolder(x['id'] as String, '/', (x['label'] as String?) ?? x['id'] as String),
    ];
  } on OpError {
    return const [];
  }
}

/// A path shown to the user: the folder label, then the path inside it.
String displayPath(SearchFolder f, String path) {
  final inner = f.path == '/' ? path : (path.startsWith(f.path) ? path.substring(f.path.length) : path);
  final p = inner.startsWith('/') ? inner.substring(1) : inner;
  return '${f.label}/$p';
}

/// WorkspacePath.normalize, for result paths the agent already made absolute.
String normalized(String p) => WorkspacePath.normalize(p);
