import 'dart:io';
import 'package:aurora_install/aurora_install.dart';

Future<void> main(List<String> args) async {
  if (Platform.environment['AURORA3_TRUST_KEY']?.isNotEmpty == true) {
    throw StateError('Unexpected test trust key');
  }
  final folder = args.single;
  for (final entry in {
    'aurora3-agent': '$folder/agent/amd64',
    'aurora3-local-agent': '$folder/local-agent/windows-amd64',
  }.entries) {
    final build = await AgentBuild.open(entry.value, product: entry.key);
    if (build.manifest.version != '3.24.0' ||
        build.manifest.keyId != '87828dfb18459372') {
      throw StateError('Wrong candidate identity');
    }
    stdout.writeln('PASS production-key signature/hash ${entry.key} ${build.manifest.version} ${build.manifest.keyId}');
  }
  final policy = await UpgradePolicy.open('$folder/agent');
  if (policy == null || policy.refusal('3.22.0', '3.24.0') != null) {
    throw StateError('Upgrade policy missing or refuses candidate');
  }
  stdout.writeln('PASS production-key upgrade policy verification');
}
