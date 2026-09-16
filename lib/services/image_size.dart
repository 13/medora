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

/// The longest side the region-pass crop decodes the photo at: a 50-200 MP
/// gallery photo decoded at full size takes 200-800 MB.
const int regionMaxDecodeSide = 4096;

/// The factor a [width] x [height] image is decoded at so its longer side
/// is at most [maxSide] pixels (1 when it already fits).
double cropDecodeScale(int width, int height, int maxSide) {
  final longest = math.max(width, height);
  return longest <= maxSide ? 1.0 : maxSide / longest;
}

/// Writes the [crop] (image pixels, rounded out to whole pixels and clamped
/// to the image) of the upright image at [path] to [outPath] as a PNG, and
/// returns the crop actually written with the [scale] its PNG holds it at
/// (PNG pixels per image pixel); null when it is empty or the image cannot
/// be read back. The image is decoded with its longer side capped at
/// [maxDecodeSide] (see [cropDecodeScale]), so a PNG box maps back to image
/// pixels as `crop.topLeft + box / scale`.
///
/// [quarterTurns] are clockwise rotations applied to the written PNG, so a
/// barcode printed sideways can be decoded; map boxes back with
/// `unrotateBox` (see `scan_region.dart`). Several rotations of one crop
/// are cheaper through [writeImageCropRotations], which decodes once.
Future<({ui.Rect crop, double scale})?> writeImageCrop(
  String path,
  ui.Rect crop,
  String outPath, {
  int maxDecodeSide = regionMaxDecodeSide,
  int quarterTurns = 0,
}) => writeImageCropRotations(path, crop, [
  (quarterTurns: quarterTurns, outPath: outPath),
], maxDecodeSide: maxDecodeSide);

/// The same crop as [writeImageCrop], written once per entry of [outputs]
/// at that entry's clockwise [quarterTurns], from a **single** decode of
/// the image at [path]: decoding a large photo per rotation costs hundreds
/// of megabytes and seconds each. Returns the crop written and the scale
/// its PNGs hold it at (the same for every entry); null when [outputs] is
/// empty, the crop is empty or the image cannot be read back, in which
/// case a later entry may be left unwritten.
Future<({ui.Rect crop, double scale})?> writeImageCropRotations(
  String path,
  ui.Rect crop,
  List<({int quarterTurns, String outPath})> outputs, {
  int maxDecodeSide = regionMaxDecodeSide,
}) async {
  if (outputs.isEmpty) return null;
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final left = math.max(0, crop.left.floor());
    final top = math.max(0, crop.top.floor());
    final right = math.min(descriptor.width, crop.right.ceil());
    final bottom = math.min(descriptor.height, crop.bottom.ceil());
    if (right <= left || bottom <= top) return null;
    final written = ui.Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    );
    final scale = cropDecodeScale(
      descriptor.width,
      descriptor.height,
      maxDecodeSide,
    );
    codec = scale == 1.0
        ? await descriptor.instantiateCodec()
        : await descriptor.instantiateCodec(
            targetWidth: math.max(1, (descriptor.width * scale).round()),
            targetHeight: math.max(1, (descriptor.height * scale).round()),
          );
    image = (await codec.getNextFrame()).image;
    final src = ui.Rect.fromLTRB(
      written.left * scale,
      written.top * scale,
      written.right * scale,
      written.bottom * scale,
    );
    final baseWidth = math.max(1, (written.width * scale).round());
    final baseHeight = math.max(1, (written.height * scale).round());
    for (final output in outputs) {
      final ok = await _writeRotation(
        image,
        src,
        baseWidth: baseWidth,
        baseHeight: baseHeight,
        quarterTurns: output.quarterTurns,
        outPath: output.outPath,
      );
      if (!ok) return null;
    }
    return (crop: written, scale: scale);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// Draws [src] of [image] into a [baseWidth] x [baseHeight] canvas turned
/// [quarterTurns] clockwise and writes it to [outPath] as a PNG; false when
/// the PNG cannot be encoded.
Future<bool> _writeRotation(
  ui.Image image,
  ui.Rect src, {
  required int baseWidth,
  required int baseHeight,
  required int quarterTurns,
  required String outPath,
}) async {
  final turns = quarterTurns % 4;
  final outWidth = turns.isEven ? baseWidth : baseHeight;
  final outHeight = turns.isEven ? baseHeight : baseWidth;
  ui.Picture? picture;
  ui.Image? cropped;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    switch (turns) {
      case 1:
        canvas.translate(outWidth.toDouble(), 0);
        canvas.rotate(math.pi / 2);
      case 2:
        canvas.translate(outWidth.toDouble(), outHeight.toDouble());
        canvas.rotate(math.pi);
      case 3:
        canvas.translate(0, outHeight.toDouble());
        canvas.rotate(-math.pi / 2);
    }
    canvas.drawImageRect(
      image,
      src,
      ui.Rect.fromLTWH(0, 0, baseWidth.toDouble(), baseHeight.toDouble()),
      ui.Paint(),
    );
    picture = recorder.endRecording();
    cropped = await picture.toImage(outWidth, outHeight);
    final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return false;
    await File(outPath).writeAsBytes(png.buffer.asUint8List(), flush: true);
    return true;
  } finally {
    cropped?.dispose();
    picture?.dispose();
  }
}
