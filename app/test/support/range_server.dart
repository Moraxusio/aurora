import 'dart:async';
import 'dart:typed_data';

import 'package:aurora/features/files/remote_bytes.dart';

import 'fake_download.dart';

/// Serves [bytes] by range, like fs.download with offset and length.
class Server {
  Uint8List bytes;
  String etag;
  final requests = <(int, int)>[];
  final streams = <FakeDownload>[];
  Completer<void>? hold; // delays the answer of the next request
  bool dropEnd = false;
  Server(this.bytes, {this.etag = 'e1'});

  Future<DownloadStream> open(String root, String path, int offset, int length) async {
    requests.add((offset, length));
    if (hold != null) {
      final h = hold!;
      hold = null;
      await h.future;
    }
    final n = offset >= bytes.length ? 0 : ((bytes.length - offset) < length ? bytes.length - offset : length);
    final s = FakeDownload(
      {'size': bytes.length, 'etag': etag, 'length': n, 'offset': offset},
      [if (n > 0) data(bytes.sublist(offset, offset + n)), if (!dropEnd) end()],
    );
    streams.add(s);
    return s;
  }
}

Uint8List seq(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) i % 251]);
