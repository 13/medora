/// Medora - image dimensions without decoding pixels
library;

import 'dart:math' as math;
import 'dart:typed_data';
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

/// Decodes the image at [path] scaled so its longer side is [maxSide]
/// pixels, as raw RGBA bytes with the decoded size; null when the image is
/// not larger than that (nothing to gain) or cannot be read back.
Future<({Uint8List rgba, int width, int height})?> decodeDownscaledRgba(
  String path,
  int maxSide,
) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = math.max(descriptor.width, descriptor.height);
    if (longest <= maxSide) return null;
    final scale = maxSide / longest;
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData();
    if (data == null) return null;
    return (
      rgba: data.buffer.asUint8List(),
      width: image.width,
      height: image.height,
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
