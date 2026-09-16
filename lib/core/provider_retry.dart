/// Medora - how a failed provider retries.
library;

import 'package:flutter_riverpod/misc.dart' show ProviderException;

/// How long Medora waits before its one automatic retry.
const _retryDelay = Duration(milliseconds: 300);

/// The retry policy the app installs on its `ProviderScope` (`main.dart`),
/// and the one `pumpMedoraApp` gives every widget test: **one quick retry,
/// then tell the user.**
///
/// A provider that is waiting out a retry stays `AsyncLoading` — it is not
/// an error state yet — so every screen built on [AsyncValueView] shows a
/// loading skeleton for as long as the policy keeps retrying, with no
/// message and no Retry button. Riverpod's default policy retries ten times
/// with a doubling backoff (200 ms up to 6.4 s), which adds up to roughly
/// thirteen seconds: a locked or corrupt SQLite file looks exactly like a
/// slow read for that whole time, and the dashboard simply appears to hang.
///
/// One 300 ms retry keeps what the backoff is actually for — a read that
/// loses a race with a concurrent write and succeeds immediately afterwards,
/// which the user never sees — and gets a real failure in front of them in
/// about a third of a second, with the Retry button that re-reads the
/// source. Retrying by hand is then the user's decision rather than
/// something the app does silently for a quarter of a minute.
///
/// What is *not* retried, matching Riverpod's own default:
/// - anything that is not an [Exception] (an [Error] is a bug in the app,
///   not a transient failure; retrying it only delays the report), and
/// - a [ProviderException], which is how a derived provider is told that the
///   provider it watches has already failed. Its source has run its own
///   retry and given up, so retrying the derivation would only repeat a
///   failure that is already final, and delay the card's error shell.
Duration? medoraRetry(int retryCount, Object error) {
  if (error is ProviderException || error is! Exception) return null;
  if (retryCount >= 1) return null;
  return _retryDelay;
}
