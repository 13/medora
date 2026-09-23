/// Medora - Reminder / Notification Service
///
/// Manages local notifications for medication dose reminders.
library;

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/reminder_text.dart';
import 'package:medora/services/stock_expiry_reminders.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Service for scheduling and managing medication reminders.
class ReminderService implements ReminderPort {
  ReminderService._();

  static final ReminderService _instance = ReminderService._();
  static ReminderService get instance => _instance;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  /// The app's router, assigned once from `main.dart`. A router is not bound
  /// to a widget's lifecycle (a [BuildContext] is), so keeping it in a static
  /// cannot leave a disposed element behind.
  ///
  /// A notification can be tapped before `main.dart` has finished building
  /// the router (e.g. a cold start from a notification). Assigning `null`
  /// clears any pending route along with the router — that reads as
  /// "detached", not "remember this for later" — while assigning a router
  /// flushes a pending route recorded by [handleNotificationTap] in the
  /// meantime.
  static GoRouter? get router => _router;

  static set router(GoRouter? value) {
    _router = value;
    if (value == null) {
      _pendingRoute = null;
      return;
    }
    final pending = _pendingRoute;
    if (pending != null) {
      _pendingRoute = null;
      // The router is installed from `initState`, so navigating straight
      // away would run during a build; defer it by a microtask.
      scheduleMicrotask(() => value.go(pending));
    }
  }

  static GoRouter? _router;
  static String? _pendingRoute;

  /// Resolves the user's chosen locale. Services must not import presentation
  /// code, so `main.dart` installs this seam next to [router]; `null` (or no
  /// seam at all) means "follow the platform locale".
  static Locale? Function()? localeResolver;

  /// Whether the current platform supports scheduled local notifications
  /// (mobile only; web and desktop plugins cannot schedule).
  static bool get _supported =>
      PlatformCapabilities.detect().hasLocalNotifications;

  /// Initialize the notification service.
  Future<void> initialize() async {
    if (!_supported) return;
    if (_isInitialized) return;

    // USE latest.dart INSTEAD OF latest_all.dart
    // This significantly reduces startup time and memory usage.
    tz.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings('ic_stat_notify');
    const iosSettings = DarwinInitializationSettings();

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    _isInitialized = true;
  }

  void _onNotificationResponse(NotificationResponse response) =>
      handleNotificationTap(response.payload);

  /// Navigate to the doses screen when a notification is tapped. When
  /// [router] has not been assigned yet (e.g. a cold start from a
  /// notification, before `main.dart` finishes building the router), the
  /// route is remembered and applied as soon as [router] is set.
  @visibleForTesting
  void handleNotificationTap(String? payload) {
    const route = '/doses';
    final currentRouter = router;
    if (currentRouter == null) {
      _pendingRoute = route;
      return;
    }
    currentRouter.go(route);
  }

  /// Localizations for the app's current locale, or `null` when it is not one
  /// of the supported locales (callers then use the English fallback text).
  @visibleForTesting
  static AppLocalizations? resolveLocalizations() {
    // An explicit preference is authoritative; only "system default" (null)
    // falls through to the platform locale.
    final locale = localeResolver?.call() ?? PlatformDispatcher.instance.locale;
    for (final supported in AppLocalizations.supportedLocales) {
      if (supported.languageCode == locale.languageCode) {
        return lookupAppLocalizations(supported);
      }
    }
    return null;
  }

  /// Title for a dose reminder fired [minutesBefore] minutes ahead of time.
  @visibleForTesting
  static String reminderTitle({
    required String medicationName,
    required int minutesBefore,
    AppLocalizations? l10n,
  }) {
    final strings = l10n ?? resolveLocalizations();
    if (strings == null) {
      return minutesBefore == 0
          ? 'Time for $medicationName'
          : 'Reminder: $medicationName in $minutesBefore min';
    }
    return minutesBefore == 0
        ? strings.notificationReminderTimeFor(medicationName)
        : strings.notificationReminderInMinutes(medicationName, minutesBefore);
  }

  /// Title for a stock, expiry or prescription-expiry notification.
  @visibleForTesting
  static String stockAlertTitle(StockAlertKind kind, {AppLocalizations? l10n}) {
    final strings = l10n ?? resolveLocalizations();
    if (strings == null) {
      return switch (kind) {
        StockAlertKind.expiry => 'Expiring soon',
        StockAlertKind.lowStock => 'Running low',
        StockAlertKind.rxExpiry => 'Prescription expiring',
      };
    }
    return switch (kind) {
      StockAlertKind.expiry => strings.notificationExpiryTitle,
      StockAlertKind.lowStock => strings.notificationLowStockTitle,
      StockAlertKind.rxExpiry => strings.notificationRxExpiryTitle,
    };
  }

  /// Body for a stock, expiry or prescription-expiry notification. The
  /// English fallbacks mirror the ARB plural branches, so an unsupported
  /// platform locale still reads naturally at 0 and 1.
  ///
  /// A low-stock alert that [StockAlert.askForRx] adds a second line asking
  /// for a new prescription — the whole point of that flag is that the
  /// notification, not just the medication screen, says so.
  @visibleForTesting
  static String stockAlertBody(StockAlert alert, {AppLocalizations? l10n}) {
    final strings = l10n ?? resolveLocalizations();
    final name = alert.medicationName;
    if (strings == null) {
      final body = switch (alert.kind) {
        StockAlertKind.expiry => switch (alert.days) {
          0 => '$name expires today',
          1 => '$name expires tomorrow',
          _ => '$name expires in ${alert.days} days',
        },
        StockAlertKind.lowStock => switch (alert.quantity) {
          0 => '$name: none left',
          1 => '$name: 1 left',
          _ => '$name: ${alert.quantity} left',
        },
        StockAlertKind.rxExpiry => switch (alert.days) {
          0 => '$name: last valid day',
          1 => '$name: valid until tomorrow',
          _ => '$name: valid ${alert.days} more days',
        },
      };
      return alert.askForRx
          ? '$body\nAsk your doctor for a new prescription'
          : body;
    }
    final body = switch (alert.kind) {
      StockAlertKind.expiry => strings.notificationExpiryBody(name, alert.days),
      StockAlertKind.lowStock => strings.notificationLowStockBody(
        name,
        alert.quantity,
      ),
      StockAlertKind.rxExpiry => strings.notificationRxExpiryBody(
        name,
        alert.days,
      ),
    };
    return alert.askForRx ? '$body\n${strings.notificationAskForRx}' : body;
  }

  @override
  Future<void> scheduleStockAlert(StockAlert alert) async {
    if (!_supported) return;
    await _ensureInitialized();
    // Deliberately the real clock, not the planner's injected one: this is
    // the last check before the OS takes over, and by now the slot planned
    // earlier may have passed — a past zonedSchedule either throws or fires
    // at once. Injecting a test clock here would silently drop every alert.
    if (!alert.when.isAfter(DateTime.now())) return;
    final l10n = resolveLocalizations();
    await _scheduleNotification(
      id: alert.id,
      title: stockAlertTitle(alert.kind, l10n: l10n),
      body: stockAlertBody(alert, l10n: l10n),
      scheduledTime: alert.when,
      // Routed like a dose reminder today; the id is carried so a tap can
      // open the medication (or, for an rxExpiry alert, the prescription)
      // itself later.
      payload: alert.kind == StockAlertKind.rxExpiry
          ? 'rx:${alert.medicationId}'
          : 'medication:${alert.medicationId}',
      l10n: l10n,
    );
  }

  @override
  Future<void> cancelStockAlert(int id) async {
    if (!_supported) return;
    await _ensureInitialized();
    await _notifications.cancel(id: id);
  }

  /// Stable 31-bit notification id base for a dose (FNV-1a over the id,
  /// low 4 bits cleared so per-dose offsets never collide).
  static int notificationBaseId(String doseId) {
    var hash = 0x811C9DC5;
    for (final unit in doseId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFF0;
  }

  @override
  Future<void> cancelAll() => cancelAllReminders();

  /// Whether [id] belongs to the stock, expiry and prescription-expiry
  /// scheduler.
  ///
  /// [stockAlertId] hands out offsets 8, 9 and 10 of the same 16-slot block
  /// the dose reminders take offsets 0-3 of, so the low nibble says who owns
  /// it. Missing offset 10 here would make a cold start's dose-reminder
  /// cancel wipe every prescription-expiry alert along with it — the same
  /// bug offsets 8 and 9 exist to prevent for the stock alerts.
  static bool _isStockAlertId(int id) =>
      const {0x8, 0x9, 0xA}.contains(id & 0xF);

  @override
  Future<void> cancelAllDoses() async {
    if (!_supported) return;
    await _ensureInitialized();
    // Enumerated rather than cancelled wholesale: `cancelAll()` would take
    // the stock and expiry alerts with it, and their owner's snapshot would
    // still claim they are booked — so they would die on every cold start
    // and never come back.
    final List<PendingNotificationRequest> pending;
    try {
      pending = await _notifications.pendingNotificationRequests();
    } catch (e) {
      // Nothing is cancelled, which is the safe half of the trade: the ids
      // are re-used in place when the doses are scheduled again, so at worst
      // a stale reminder survives until its own dose is reconciled.
      debugPrint('Reminders: could not list pending notifications: $e');
      return;
    }
    for (final request in pending) {
      if (_isStockAlertId(request.id)) continue;
      await _notifications.cancel(id: request.id);
    }
  }

  @override
  Future<void> cancelForDose(String doseId) async {
    if (!_supported) return;
    await _ensureInitialized();
    final baseId = notificationBaseId(doseId);
    for (var i = 0; i < 4; i++) {
      await _notifications.cancel(id: baseId + i);
    }
  }

  @override
  Future<void> scheduleForDose({
    required DoseLog dose,
    required String medicationName,
  }) => scheduleRemindersForDose(dose: dose, medicationName: medicationName);

  /// Schedule reminders for a dose.
  Future<void> scheduleRemindersForDose({
    required DoseLog dose,
    required String medicationName,
  }) async {
    if (!_supported) return;

    await _ensureInitialized();

    final now = DateTime.now();
    final baseId = notificationBaseId(dose.id);
    final offsets = [60, 0];

    // Resolve strings without a BuildContext — a background notification has
    // no widget tree to read from.
    final l10n = resolveLocalizations();

    for (var i = 0; i < offsets.length; i++) {
      final scheduledTime = dose.scheduledTime.subtract(
        Duration(minutes: offsets[i]),
      );
      if (scheduledTime.isBefore(now)) continue;

      final title = reminderTitle(
        medicationName: medicationName,
        minutesBefore: offsets[i],
        l10n: l10n,
      );

      String body;
      if (l10n != null) {
        body = reminderBody(l10n, dose);
      } else {
        body = '${dose.displayDosage ?? ""} — Tap to log your dose';
      }

      await _scheduleNotification(
        id: baseId + i,
        title: title,
        body: body,
        scheduledTime: scheduledTime,
        payload: dose.id,
        l10n: l10n,
      );
    }
  }

  Future<void> _scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
    AppLocalizations? l10n,
  }) async {
    if (!_supported) return;

    final tzScheduledTime = tz.TZDateTime.from(scheduledTime, tz.local);

    final androidDetails = AndroidNotificationDetails(
      'medora_dose_reminders',
      l10n?.notificationChannelName ?? 'Dose Reminders',
      channelDescription:
          l10n?.notificationChannelDescription ??
          'Reminders for scheduled medication doses',
      importance: Importance.max,
      priority: Priority.high,
      ticker: l10n?.notificationTicker ?? 'Medication Reminder',
      icon: 'ic_stat_notify',
      category: AndroidNotificationCategory.reminder,
      color: const Color(0xFF2196F3),
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );

    await _notifications.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tzScheduledTime,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payload,
    );
  }

  Future<void> cancelAllReminders() async {
    if (!_supported) return;
    await _ensureInitialized();
    await _notifications.cancelAll();
  }

  @override
  Future<bool> ensurePermissions() => requestPermissions();

  Future<bool> requestPermissions() async {
    if (!_supported) return true;

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      return await androidPlugin.requestNotificationsPermission() ?? false;
    }
    // iOS answers from its stored decision after the first prompt, so this
    // is safe to call on every reconcile. Without it the app would report
    // "permitted" on the one platform where the answer is most likely to be
    // no — and the whole pending-notification budget exists for iOS's cap.
    final iosPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosPlugin != null) {
      return await iosPlugin.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    return true;
  }

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) await initialize();
  }
}
