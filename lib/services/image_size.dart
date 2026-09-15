/// Medora - image dimensions without decoding pixels
library;

import 'dart:io';
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

/// Writes the [crop] (image pixels, rounded out to whole pixels and clamped
/// to the image) of the upright image at [path] to [outPath] as a PNG, and
/// returns the crop actually written; null when it is empty or the image
/// cannot be read back. The image is decoded at full resolution.
Future<ui.Rect?> writeImageCrop(
  String path,
  ui.Rect crop,
  String outPath,
) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  ui.Picture? picture;
  ui.Image? cropped;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final left = math.max(0, crop.left.floor());
    final top = math.max(0, crop.top.floor());
    final right = math.min(descriptor.width, crop.right.ceil());
    final bottom = math.min(descriptor.height, crop.bottom.ceil());
    if (right <= left || bottom <= top) return null;
    final src = ui.Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    );
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      src,
      ui.Rect.fromLTWH(0, 0, src.width, src.height),
      ui.Paint(),
    );
    picture = recorder.endRecording();
    cropped = await picture.toImage(right - left, bottom - top);
    final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    await File(outPath).writeAsBytes(png.buffer.asUint8List(), flush: true);
    return src;
  } finally {
    cropped?.dispose();
    picture?.dispose();
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
