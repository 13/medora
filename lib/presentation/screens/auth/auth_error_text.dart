/// What an authentication failure says to the person who caused it.
///
/// The screen used to show `next.error.toString()`, which reaches a user as
/// `AuthApiException(message: User already registered, statusCode: 400)`.
/// That names the class that failed, not the thing they got wrong.
///
/// Only failures that actually happen at this form are mapped. Anything else
/// keeps its raw text rather than being flattened into "something went
/// wrong": an unknown failure the user can quote is worth more than a tidy
/// sentence that says nothing.
library;

import 'dart:io';

import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Seconds Supabase asks a caller to wait, lifted out of messages like
/// "For security purposes, you can only request this after 49 seconds."
int? retryAfterSeconds(String message) {
  final match = RegExp(r'after (\d+) seconds?').firstMatch(message);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String authErrorMessage(Object error, AppLocalizations l10n) {
  if (error is SocketException || error is HttpException) {
    return l10n.authOffline;
  }
  if (error is! AuthException) return error.toString();

  final message = error.message;
  final lower = message.toLowerCase();

  // Supabase phrases these in prose and the wording has changed between
  // versions, so match on the part that has not: the subject, not the
  // sentence.
  if (lower.contains('already registered') ||
      lower.contains('already been registered')) {
    return l10n.authEmailTaken;
  }
  if (lower.contains('invalid login credentials')) {
    return l10n.authInvalidCredentials;
  }
  if (lower.contains('password should be') || lower.contains('weak password')) {
    return l10n.authWeakPassword;
  }
  if (lower.contains('invalid email') ||
      lower.contains('unable to validate email')) {
    return l10n.authInvalidEmail;
  }
  if (lower.contains('for security purposes') ||
      lower.contains('rate limit') ||
      lower.contains('too many requests')) {
    final seconds = retryAfterSeconds(message);
    return seconds == null ? message : l10n.authRateLimited(seconds);
  }
  return message;
}
