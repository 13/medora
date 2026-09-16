import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/release_notes.dart';

void main() {
  test('headings keep their words', () {
    expect(
      releaseNotesToPlainText('## What changed\ntext'),
      'What changed\ntext',
    );
  });

  test('list markers become bullets', () {
    expect(
      releaseNotesToPlainText('- one\n* two\n+ three\n1. four'),
      '• one\n• two\n• three\n• four',
    );
  });

  test('links keep their text', () {
    expect(
      releaseNotesToPlainText('see [the PR](https://example.com/pr/1)'),
      'see the PR',
    );
  });

  test('emphasis and code markers are dropped', () {
    expect(
      releaseNotesToPlainText('**bold** _it_ `code` ~~gone~~'),
      'bold it code gone',
    );
  });

  test('images, comments and the changelog trailer are removed', () {
    expect(
      releaseNotesToPlainText(
        'real\n![shot](https://x/y.png)\n<!-- hidden -->\n'
        '**Full Changelog**: https://github.com/13/medora/compare/v1...v2',
      ),
      'real',
    );
  });

  test('blank line runs collapse', () {
    expect(releaseNotesToPlainText('a\n\n\n\nb'), 'a\n\nb');
  });

  test('empty or marker-only input yields an empty string', () {
    expect(releaseNotesToPlainText('   \n\n'), '');
    expect(releaseNotesToPlainText('---'), '');
  });

  test('very long notes are cut at a line boundary with an ellipsis', () {
    final long = List.generate(600, (i) => 'line $i').join('\n');
    final text = releaseNotesToPlainText(long);
    expect(text.length, lessThanOrEqualTo(releaseNotesMaxChars + 1));
    expect(text, endsWith('…'));
    expect(text, contains('line 0'));
  });

  test('a bracket storm renders promptly instead of backtracking', () {
    // A release body that pastes in a build log or a JSON dump: thousands of
    // '[' with no closing ']'. Each one must fail the link pattern in
    // constant time instead of scanning the rest of the body.
    final storm = '[' * 30000;
    final watch = Stopwatch()..start();
    final text = releaseNotesToPlainText(storm);
    watch.stop();

    expect(
      watch.elapsedMilliseconds,
      lessThan(500),
      reason: 'rendering backtracked: took ${watch.elapsedMilliseconds} ms',
    );
    expect(text, '${'[' * releaseNotesMaxChars}…');
  });

  test('an enormous body is bounded before any of it is rendered', () {
    // Only the tail carries words, and it sits far past the input bound, so
    // it never reaches the renderer. The output is capped at 4000 characters
    // anyway, so nothing that could have been shown is lost.
    final padding = '\n' * (releaseNotesMaxInputChars + 1000);
    expect(releaseNotesToPlainText('${padding}tail'), '');
    // Well inside the bound, the same tail survives.
    expect(releaseNotesToPlainText('${'\n' * 1000}tail'), 'tail');
  });

  test('brackets nested in link and image syntax read the same as before', () {
    expect(releaseNotesToPlainText('[![img](a.png)](https://b)'), '');
    expect(
      releaseNotesToPlainText('real ![shot](https://x/y.png) tail'),
      'real  tail',
    );
  });
}
