# Sign-up feedback, and the confirmation link that pointed at localhost — Implementation Plan

**Date:** 2026-09-22. **Branch:** `main`, from v0.4.3+22.

Two reports, one root cause apart.

1. **Registering for cloud says nothing.** `_submit` (`auth_screen.dart:37`)
   awaits `signUpWithEmail`, checks for an error, and calls
   `_claimLocalDataForSignedInUser`, which returns at `if (userId == null)`.
   With e-mail confirmation on, a successful sign-up returns **no session**,
   so that is exactly the path taken: the spinner stops and the form sits
   there. No message, no navigation, nothing to tell a person whether an
   account now exists.
2. **The confirmation e-mail links to localhost.** `auth.signUp`
   (`auth_providers.dart:58`) passes no `emailRedirectTo`, so Supabase falls
   back to the project's Site URL, which a new project defaults to
   `http://localhost:3000`. There is also no deep link to fall back *to*:
   `AndroidManifest.xml` carries only a LAUNCHER intent-filter and the
   project has no `app_links`/`uni_links` dependency.

## The decision

E-mail confirmation is **off** (dashboard → Authentication → Sign In /
Providers → Email → *Confirm email*). `signUp` then returns a session
immediately, the router redirects, and the claim-local-data flow that
already exists runs as it was always meant to. No deep link, no new
dependency, no platform manifest work.

Two consequences worth stating. Addresses are unverified — acceptable for an
app whose data lives on the device and whose account exists only to sync it.
And a future password reset needs the same redirect machinery this avoids,
so that work does not get cheaper by deciding this way; it stays where it is
today, which is absent.

Under `Supabase.initialize`'s default **PKCE** flow a confirmation link
carries a code only the app can exchange, so a hosted landing page could not
have finished the job either. That is why the choice was between "off" and
"a real deep link", with nothing useful in between.

## The app must not assume it

One dashboard toggle away, sign-up returns no session again — and a
self-hosted or differently-configured project may have it on from the start.
So the silent path gets fixed on its own terms rather than deleted: when no
session comes back, the screen says so and offers to send the mail again.

## Steps

- [ ] **Step 1 — tests first** (`test/presentation/screens/auth_screen_test.dart`)
  - sign-up returning a session claims the local rows and leaves the screen
    (pins today's behaviour)
  - sign-up returning **no** session shows a "check your e-mail" panel naming
    the address, with Resend — the case that currently renders nothing
  - Resend twice: the second is refused by the cooldown
  - `AuthApiException('User already registered')` reaches the user as a
    sentence, not `AuthApiException(message: …, statusCode: 400)`
  - an offline sign-up says it is offline

- [ ] **Step 2 — an outcome instead of `void`.** `signUpWithEmail` returns
  `SignUpOutcome.signedIn | confirmationRequired`, decided by whether the
  client has a session afterwards. `_submit` branches on it.

- [ ] **Step 3 — the panel.** On `confirmationRequired` the form is replaced
  in place by a card naming the address, a Resend button with a 60-second
  cooldown, and a way back. No new route.

- [ ] **Step 4 — error strings.** `authErrorMessage(Object, AppLocalizations)`
  maps what actually occurs — already registered, invalid credentials, weak
  password, invalid e-mail, rate limited (with Supabase's retry seconds
  lifted out of the message), offline — and falls back to the raw text rather
  than swallowing an unknown failure. Replaces `next.error.toString()` at
  `auth_screen.dart:118`. New keys in `app_en/de/it.arb`, then `gen-l10n`.

- [ ] **Step 5 — write down the trap.** README's cloud-sync section: e-mail
  confirmation is expected off; turning it on needs a deep link
  (`app_links`, a `medora://` scheme, an intent-filter, `CFBundleURLTypes`,
  `emailRedirectTo`, and the dashboard's redirect allow-list) or users get a
  link to whatever Site URL says. Note the PKCE constraint so the next person
  does not try to solve it with a web page.

- [ ] **Step 6 — gates and release.** `analyze --fatal-infos`, `dart format`,
  the full suite in both zones and through the fake HTTP transport, then a
  tagged release.

## Not in this plan

There is no password reset anywhere in the app. Someone who forgets their
password has no route back in. It needs the redirect work this plan avoids,
and it deserves its own.

## What is true when this is done

A person who registers either lands in the app signed in, or reads a card
telling them to check their mail with a button to send it again. A person who
mistypes an address, reuses one, or is offline reads a sentence about it.
Nobody is sent to `localhost`.
