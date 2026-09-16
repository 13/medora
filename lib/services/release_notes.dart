/// Medora - GitHub release notes as readable text
///
/// The update sheet shows the release body, which is markdown. Rendering it
/// properly would mean a markdown dependency for one paragraph of text, so
/// this strips it to plain text instead: the words survive, the syntax does
/// not. Pure Dart, unit-tested directly.
library;

/// The longest "what's new" the sheet shows before collapsing.
const int releaseNotesCollapsedChars = 400;

/// The most it ever shows, expanded.
const int releaseNotesMaxChars = 4000;

final _comment = RegExp(r'<!--.*?-->', dotAll: true);
final _image = RegExp(r'!\[[^\]]*\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');
final _heading = RegExp(r'^\s{0,3}#{1,6}\s*');
final _bullet = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+');
final _rule = RegExp(r'^\s*(?:[-*_]\s*){3,}$');
final _trailer = RegExp(
  r'^\*{0,2}Full Changelog\*{0,2}\s*:',
  caseSensitive: false,
);
final _emphasis = RegExp(r'(\*{1,3}|_{1,3}|~~|`+)');
final _blockQuote = RegExp(r'^\s*>\s?');

/// GitHub release markdown as plain text.
///
/// Headings lose their `#` and keep their words, list items become `• `,
/// links become their text, inline code/emphasis markers are dropped,
/// `<!-- -->` comments, images and the auto-generated "**Full Changelog**"
/// trailer are removed, and runs of blank lines collapse to one. Never
/// longer than [releaseNotesMaxChars] (cut at a line boundary, with a
/// trailing `…`).
String releaseNotesToPlainText(String markdown) {
  var text = markdown.replaceAll(_comment, '').replaceAll(_image, '');
  text = text.replaceAllMapped(_link, (m) => m[1] ?? '');
  final lines = <String>[];
  for (final raw in text.split('\n')) {
    var line = raw.replaceAll('\r', '');
    if (_rule.hasMatch(line)) continue;
    if (_trailer.hasMatch(line.trim())) continue;
    line = line.replaceFirst(_blockQuote, '');
    final isBullet = _bullet.hasMatch(line);
    line = line.replaceFirst(_heading, '').replaceFirst(_bullet, '');
    line = line.replaceAll(_emphasis, '').trimRight();
    if (isBullet && line.trim().isNotEmpty) line = '• ${line.trim()}';
    lines.add(line.trimLeft());
  }
  // Collapse blank runs, and drop the leading and trailing ones entirely.
  final out = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(line.trim().isEmpty ? '' : line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  final joined = out.join('\n');
  if (joined.length <= releaseNotesMaxChars) return joined;
  final cut = joined.lastIndexOf('\n', releaseNotesMaxChars);
  return '${joined.substring(0, cut > 0 ? cut : releaseNotesMaxChars).trimRight()}…';
}
