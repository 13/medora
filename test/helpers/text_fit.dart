/// Measures whether a piece of text fits the box it was laid out in.
///
/// Text that is clipped, ellipsized or broken mid-word throws nothing, so
/// layout tests compare what the text wants against what it got. Call
/// `loadAppFonts()` first: in the default test font a label measures about
/// three times as wide as on a device.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a paragraph wants against what it was given, in logical pixels.
///
/// [minIntrinsic] is its longest unbreakable run (wider than [maxWidth]
/// means a mid-word break); [maxIntrinsic] is the whole text on one line
/// (wider than [maxWidth] means the label wraps or, on one line, is cut).
/// [exceeded] is true when the paragraph hit its `maxLines` and was cut.
typedef TextFit = ({
  double minIntrinsic,
  double maxIntrinsic,
  double maxWidth,
  bool exceeded,
});

TextFit measureText(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: text, matching: find.byType(RichText), matchRoot: true),
  );
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
  )..layout();
  addTearDown(painter.dispose);
  return (
    minIntrinsic: painter.minIntrinsicWidth,
    maxIntrinsic: painter.maxIntrinsicWidth,
    maxWidth: paragraph.constraints.maxWidth,
    exceeded: paragraph.didExceedMaxLines,
  );
}

/// A 360 x 900 dp phone at 1.0 device pixel ratio.
void usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// [child] under the ambient MediaQuery with only the text scale changed.
Widget withTextScale(double scale, Widget child) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child,
  ),
);
