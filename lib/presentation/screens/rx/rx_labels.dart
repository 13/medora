/// Medora - Display names of prescription kinds, states and priorities.
library;

import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

String rxKindLabel(AppLocalizations l10n, RxKind kind) => switch (kind) {
  RxKind.ssn => l10n.rxKindSsn,
  RxKind.white => l10n.rxKindWhite,
  RxKind.whiteRepeatable => l10n.rxKindWhiteRepeatable,
  RxKind.referral => l10n.rxKindReferral,
};

String rxKindShort(AppLocalizations l10n, RxKind kind) => switch (kind) {
  RxKind.ssn => l10n.rxKindShortSsn,
  RxKind.white => l10n.rxKindShortWhite,
  RxKind.whiteRepeatable => l10n.rxKindShortWhiteRepeatable,
  RxKind.referral => l10n.rxKindShortReferral,
};

String rxStatusLabel(AppLocalizations l10n, RxStatus status) =>
    switch (status) {
      RxStatus.open => l10n.rxStatusOpen,
      RxStatus.partial => l10n.rxStatusPartial,
      RxStatus.redeemed => l10n.rxStatusRedeemed,
      RxStatus.expired => l10n.rxStatusExpired,
      RxStatus.cancelled => l10n.rxStatusCancelled,
    };

String rxPriorityLabel(AppLocalizations l10n, RxPriority p) => switch (p) {
  RxPriority.u => l10n.rxPriorityU,
  RxPriority.b => l10n.rxPriorityB,
  RxPriority.d => l10n.rxPriorityD,
  RxPriority.p => l10n.rxPriorityP,
};
