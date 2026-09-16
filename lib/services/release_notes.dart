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

/// The most input it ever looks at.
///
/// A GitHub body can run to six figures of characters, and the output is
/// capped at [releaseNotesMaxChars] anyway, so nothing past this bound could
/// ever be shown - cutting here keeps a pasted build log from costing the UI
/// isolate a frame.
const int releaseNotesMaxInputChars = 64 * 1024;

final _comment = RegExp(r'<!--.*?-->', dotAll: true);
// The inner classes exclude their own opening bracket: without that, an
// unmatched '[' makes [^\]]* consume the rest of the body before failing, so
// a run of them costs O(n^2). Excluding '[' fails each attempt at once.
final _image = RegExp(r'!\[[^\[\]]*\]\([^()]*\)');
final _link = RegExp(r'\[([^\[\]]*)\]\([^()]*\)');
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
/// trailing `…`), and never reads more than [releaseNotesMaxInputChars].
String releaseNotesToPlainText(String markdown) {
  // Bound the input first: every pass below is linear in its length, so the
  // cut has to come before the work, not after it.
  final source = markdown.length > releaseNotesMaxInputChars
      ? markdown.substring(0, releaseNotesMaxInputChars)
      : markdown;
  var text = source.replaceAll(_comment, '').replaceAll(_image, '');
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
