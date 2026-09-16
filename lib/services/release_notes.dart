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
// Paired emphasis and inline code only.
//
// release_notes.sh publishes raw commit subjects, so snake_case identifiers
// and globs reach the sheet routinely; stripping every '*', '_', '~~' and
// '`' on sight turned "rename user_id to userId" into "rename userid to
// userId" and "**/*.g.dart" into "*/.g.dart". Each branch below therefore
// needs a closer of its own kind, and:
//   - the opener may not follow a word character or another marker, which is
//     what stops intra-word '_' (user_id) and the second '*' of a '**/' glob
//     from opening a run;
//   - a run may not contain its own marker, so an unpaired '*' cannot reach
//     across the next one to find a partner;
//   - a run may not begin or end on whitespace, nor end mid-word;
//   - a run is capped at 200 characters, so a line of unpaired markers costs
//     O(n) attempts of bounded width rather than O(n^2).
// Inline code is exempt from the word-boundary rules - `fixed` mid-word is
// still code - but its delimiter run is capped at 3 for the same reason.
final _emphasis = RegExp(
  r'(?<![A-Za-z0-9*_~`])(?:'
  r'(\*{1,3})(?![\s*])([^*]{1,200}?)(?<!\s)\1'
  r'|(_{1,3})(?![\s_])([^_]{1,200}?)(?<!\s)\3'
  r'|(~~)(?![\s~])([^~]{1,200}?)(?<!\s)\5'
  r')(?![A-Za-z0-9])'
  r'|(`{1,3})([^`]{1,200}?)\7',
);
// A fenced code block's opening or closing line: the fence and its optional
// info string carry no words worth showing, but the lines between them do.
final _fence = RegExp(r'^\s*(?:`{3,}|~{3,})\s*[A-Za-z0-9_+#-]*\s*$');
final _blockQuote = RegExp(r'^\s*>\s?');

/// GitHub release markdown as plain text.
///
/// Headings lose their `#` and keep their words, list items become `• `,
/// links become their text, paired inline-code and emphasis markers are
/// dropped while unpaired ones (`user_id`, `*.dart`) are left alone, code
/// fence lines are removed,
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
    if (_fence.hasMatch(line)) continue;
    if (_trailer.hasMatch(line.trim())) continue;
    line = line.replaceFirst(_blockQuote, '');
    final isBullet = _bullet.hasMatch(line);
    line = line.replaceFirst(_heading, '').replaceFirst(_bullet, '');
    line = _stripEmphasis(line).trimRight();
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

/// [line] with paired emphasis removed, repeatedly, so nesting such as
/// `**bold _it_**` loses both pairs.
///
/// Each pass is a fresh linear scan and three levels of nesting is already
/// more than a commit subject ever carries, so the loop is bounded rather
/// than run to a fixed point.
String _stripEmphasis(String line) {
  var text = line;
  for (var pass = 0; pass < 3; pass++) {
    final next = text.replaceAllMapped(
      _emphasis,
      (m) => m[2] ?? m[4] ?? m[6] ?? m[8] ?? '',
    );
    if (next == text) break;
    text = next;
  }
  return text;
}
