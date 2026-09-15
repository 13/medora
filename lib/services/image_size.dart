/// Medora - image dimensions without decoding pixels
library;

import 'dart:ui' as ui;

/// Reads the pixel size of the encoded image at [path] from its header only
/// (no full decode), so large gallery photos do not allocate a bitmap.
Future<ui.Size> readImageSize(String path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = ui.Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    return size;
  } finally {
    buffer.dispose();
  }
}
