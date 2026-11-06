/// Aurora's client protocol in pure Dart: the direct link to an agent
/// (pinned TLS, Hello, yamux) and its operation frames.
library;

export 'src/bytes.dart' show ByteQueue;
export 'src/connection.dart';
export 'src/frame.dart';
export 'src/link.dart';
export 'src/terminal.dart';
export 'src/yamux.dart'
    show
        Priority,
        Session,
        SessionClosed,
        StreamReset,
        Transport,
        YamuxConfig,
        YamuxException,
        YamuxStream;
