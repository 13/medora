/// Medora - ML Kit text recognition → domain OCR lines
///
/// The only place that maps `google_mlkit_text_recognition` types to the
/// pure [OcrLine] / [OcrElement] model used by `findCodeCandidates`.
library;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:medora/services/code_candidates.dart';

/// All recognised lines, block by block, with image-pixel boxes.
List<OcrLine> ocrLinesFrom(RecognizedText recognized) => [
  for (final block in recognized.blocks)
    for (final line in block.lines)
      OcrLine(line.text, line.boundingBox, [
        for (final element in line.elements)
          OcrElement(element.text, element.boundingBox),
      ]),
];
