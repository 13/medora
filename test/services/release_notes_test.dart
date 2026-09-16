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
}
