import 'dart:io';

/// Run with `dart tool/ui_contract.dart`; no build hooks or analyzer APIs.
void main(List<String> args) {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  if (args.contains('--inventory')) {
    final names = <String, Set<String>>{};
    for (final file in files) {
      final source = file.readAsStringSync();
      final pattern = RegExp(
        r'\b(TextField|FilledButton|OutlinedButton|TextButton|ElevatedButton|AlertDialog)(?:\.(icon|tonal|tonalIcon))?\s*\(',
      );
      for (final match in pattern.allMatches(source)) {
        var depth = 1, i = match.end;
        String? quote;
        final top = StringBuffer();
        while (i < source.length && depth > 0) {
          final c = source[i++];
          if (quote != null) {
            if (c == r'\') {
              i++;
            } else if (c == quote) {
              quote = null;
            }
          } else if (c == '"' || c == "'") {
            quote = c;
          } else if ('([{'.contains(c)) {
            depth++;
          } else if (')]}'.contains(c)) {
            depth--;
          } else if (depth == 1) {
            top.write(c);
          }
        }
        final keys = names[match[1]!] ??= {};
        keys.addAll(
          RegExp(r'(\w+)\s*:').allMatches(top.toString()).map((m) => m[1]!),
        );
      }
    }
    for (final entry in names.entries) {
      stdout.writeln(
        '${entry.key}: ${(entry.value.toList()..sort()).join(', ')}',
      );
    }
    return;
  }
  const implementation = {
    'lib/ui/aurora_ui.dart',
    'lib/ui/controls.dart',
    'lib/ui/workbench_components.dart',
    'lib/theme/ide_theme.dart',
    'lib/theme/workbench_tokens.dart',
    'lib/theme/workbench_scale.dart',
  };
  final errors = <String>[];
  for (final file in files) {
    final path = file.path.replaceAll(r'\', '/');
    if (implementation.contains(path)) continue;
    final source = file.readAsStringSync();
    if (RegExp(r'''(?:import|export)\s+['"]package:flutter/material.dart['"]''')
        .hasMatch(source)) {
      errors.add('$path: use package:aurora/ui/aurora_ui.dart');
    }
    if (RegExp(r'\b(showDialog|showMenu)\s*(?:<[^>]+>)?\s*\(')
            .hasMatch(source) &&
        path != 'lib/kernel/overlays.dart') {
      errors.add(
        '$path: use showWorkbenchDialog/showWorkbenchMenu for scaled overlays',
      );
    }
  }
  if (errors.isNotEmpty) {
    stderr.writeln(errors.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln('GUI contract passed: ${files.length} Dart source files.');
  }
}
