/// Medora - one pending-notification budget for the whole app.
///
/// iOS keeps at most 64 pending local notifications and silently drops the
/// rest, so two schedulers sizing themselves independently can quietly evict
/// each other's work. Both therefore draw from one budget: the dose
/// reminders take the larger share because they are the app's primary safety
/// function, and the stock and expiry alerts take the remainder. The shares
/// add up to [kMaxPendingNotifications], which is what keeps the app under
/// the platform cap however full the cabinet is.
library;

/// Everything the app will ever have pending at once. iOS allows 64.
const int kMaxPendingNotifications = 60;

/// The dose reminders' share (`ReminderScheduler.maxNotifications`), spent
/// two notifications at a time — 60 min before the dose and at the dose.
const int kDoseNotificationBudget = 48;

/// The stock and expiry alerts' share, one notification per alert.
///
/// Small on purpose: alerts are re-planned on every launch and resume, and
/// only those inside `stockAlertHorizonDays` are booked at all, so a short
/// queue of the nearest alerts is all that is ever needed.
const int kStockNotificationBudget =
    kMaxPendingNotifications - kDoseNotificationBudget;
