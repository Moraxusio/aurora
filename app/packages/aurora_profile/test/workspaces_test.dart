import 'dart:convert';
import 'dart:io';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:test/test.dart';

WorkspacePath path(String value, [String root = 'home']) => WorkspacePath(root: root, path: value);

Profile fixture() => Profile(servers: [ServerEntry(id: 'server', name: 'fixture', selectedWorkspace: 'project',
  browserView: WorkspaceView(treeSet: true),
  workspaces: [ProjectWorkspace(id: 'project', name: '项目', folders: [path('/src'), path('/docs', 'data')],
    view: WorkspaceView(expanded: [path('/src'), path('/src/lib')], files: [path('/src/main.dart')],
      activeFile: path('/src/main.dart'), treeSet: true))])], selected: 'server');

void main() {
  test('old profiles have browser view and do not gain non-empty workspace keys', () {
    final server = ServerEntry.fromJson({'id': 'old', 'name': 'old client'});
    expect(server.workspaces, isEmpty);
    expect(server.selectedWorkspace, isNull);
    expect(server.browserView.isEmpty, isTrue);
    expect(server.toJson(), {'id': 'old', 'name': 'old client'});
  });
  test('workspace JSON round trip includes folders, collapsed tree and file references', () {
    final p = fixture();
    final copy = Profile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(copy.toJson(), p.toJson());
    expect(copy.servers.single.browserView.treeSet, isTrue);
    expect(copy.servers.single.browserView.expanded, isEmpty);
    expect(copy.servers.single.workspace('project')!.folders, [path('/src'), path('/docs', 'data')]);
  });
  test('profile copies do not share mutable lists or view state', () {
    final p = fixture(), copy = fixture().copy();
    copy.servers.single.workspace('project')!.view.files.clear();
    copy.servers.single.workspace('project')!.folders.clear();
    copy.servers.single.browserView.treeSet = false;
    expect(p.servers.single.workspace('project')!.view.files, hasLength(1));
    expect(p.servers.single.workspace('project')!.folders, hasLength(2));
    expect(p.servers.single.browserView.treeSet, isTrue);
  });
  test('paths normalize and containment respects root and component boundaries', () {
    expect(path('src//./main.dart/'), path('/src/main.dart'));
    expect(path(''), path('/'));
    expect({path('src'), path('/src/')}, hasLength(1));
    expect(path('/src').contains(path('/src/a')), isTrue);
    expect(path('/src').contains(path('/src-other/a')), isFalse);
    expect(path('/').contains(path('/anything')), isTrue);
    expect(path('/').contains(path('/anything', 'data')), isFalse);
  });
  test('parent traversal and NUL are rejected in every workspace path source', () {
    for (final bad in ['..', '/../secret', 'src/../secret', 'src/../../a', '/src/\u0000file']) {
      expect(() => path(bad), throwsFormatException);
      final json = fixture().toJson();
      final server = (json['servers'] as List).single as Map;
      final project = (server['workspaces'] as List).single as Map;
      project['folders'] = [{'root': 'home', 'path': bad}];
      expect(() => Profile.fromJson(json), throwsFormatException);
    }
    expect(() => path('/', ''), throwsFormatException);
    expect(() => path('/', 'nul\u0000'), throwsFormatException);
  });
  test('workspace paths and names are DPAPI sealed and re-open with file refs only', () async {
    final dir = await Directory.systemTemp.createTemp('aurora3-workspace-profile-');
    addTearDown(() => dir.delete(recursive: true));
    final file = '${dir.path}${Platform.pathSeparator}profile.bin';
    final store = await ProfileStore.open(file, DpapiSealer());
    await store.update((p) { p.servers = fixture().servers; p.selected = 'server'; });
    await store.close();
    final raw = latin1.decode(await File(file).readAsBytes(), allowInvalid: true);
    for (final secret in ['main.dart', '/src', '/docs', 'project']) { expect(raw, isNot(contains(secret))); }
    final reopened = await ProfileStore.open(file, DpapiSealer());
    expect(reopened.get().toJson(), fixture().toJson());
    final serialized = jsonEncode(reopened.get().toJson());
    expect(serialized, isNot(contains('content')));
    expect(serialized, isNot(contains('unsaved')));
    final snapshot = reopened.server('server')!;
    snapshot.workspaces.single.view.files.clear();
    expect(reopened.server('server')!.workspaces.single.view.files, hasLength(1));
    await reopened.close();
  }, skip: !Platform.isWindows);
}
