// What a file is, by its name, decides which viewer opens it (like v2's
// kindOf): text goes to the editor; images, PDF, video and audio get a viewer
// of their own, because their bytes are not text and saving them as text
// would damage them.
enum FileKind { text, image, pdf, video, audio }

/// A text file that also has a rendered view next to the editor.
enum PreviewKind { none, markdown, csv }

// Formats Flutter's image codecs decode on every platform we ship. SVG is XML
// text, so it opens in the editor (nothing here renders it). AVIF and HEIC are
// left out: the platform codecs do not all handle them, and a viewer that
// fails on some phones is worse than the "download" fallback.
const imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'wbmp'};
const videoExts = {'mp4', 'm4v', 'mov', 'webm', 'mkv', 'ogv', 'avi', 'wmv', 'flv', '3gp'};
const audioExts = {'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'oga', 'opus', 'wma'};

String extOf(String path) {
  final base = path.split('/').last.toLowerCase();
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? '' : base.substring(dot + 1);
}

FileKind kindOf(String path) {
  final ext = extOf(path);
  if (imageExts.contains(ext)) return FileKind.image;
  if (ext == 'pdf') return FileKind.pdf;
  if (videoExts.contains(ext)) return FileKind.video;
  if (audioExts.contains(ext)) return FileKind.audio;
  return FileKind.text;
}

PreviewKind previewOf(String path) => switch (extOf(path)) {
      'md' || 'markdown' => PreviewKind.markdown,
      'csv' || 'tsv' => PreviewKind.csv,
      _ => PreviewKind.none,
    };

typedef WorkspaceFileLink = ({String path, int? line, int col});

/// Extracts a workspace file path and optional 1-based line/column from a
/// Markdown link [href]. Returns null for external URLs (http/https/mailto)
/// or in-document anchors.
WorkspaceFileLink? parseWorkspaceFileHref(String href) {
  final raw = href.trim();
  if (raw.isEmpty || raw.startsWith('#')) return null;
  (int?, int) parseFragment(String frag) {
    final m = RegExp(
      r'^(?:L|line=?)?(\d+)(?:[C:](\d+))?(?:-L?\d+(?:[C:]\d+)?)?$',
      caseSensitive: false,
    ).firstMatch(frag.trim());
    if (m == null) return (null, 1);
    return (int.tryParse(m.group(1)!), int.tryParse(m.group(2) ?? '') ?? 1);
  }

  String decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      return s;
    }
  }

  if (raw.toLowerCase().startsWith('file://')) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    var path = decode(uri.path);
    if (RegExp(r'^/[A-Za-z]:[/\\]').hasMatch(path)) {
      path = path.substring(1);
    }
    if (path.isEmpty) return null;
    final (line, col) = parseFragment(uri.fragment);
    return (path: path, line: line, col: col);
  }
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(raw) &&
      !RegExp(r'^[A-Za-z]:[/\\]').hasMatch(raw)) {
    return null;
  }
  var pathPart = raw;
  int? line;
  var col = 1;
  final hash = pathPart.indexOf('#');
  if (hash >= 0) {
    final (l, c) = parseFragment(pathPart.substring(hash + 1));
    line = l;
    col = c;
    pathPart = pathPart.substring(0, hash);
  } else {
    final suffix = RegExp(r':(\d+)(?::(\d+))?$').firstMatch(pathPart);
    if (suffix != null && suffix.start > 1) {
      line = int.tryParse(suffix.group(1)!);
      col = int.tryParse(suffix.group(2) ?? '') ?? 1;
      pathPart = pathPart.substring(0, suffix.start);
    }
  }
  pathPart = decode(pathPart).trim();
  if (pathPart.isEmpty) return null;
  return (path: pathPart, line: line, col: col);
}
