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
