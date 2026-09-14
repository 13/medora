/// Medora - Reminder / Notification Service
///
/// Manages local notifications for medication dose reminders.
library;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/reminder_port.dart';
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

  // Store navigation callback
  static BuildContext? _navigationContext;

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

  void _onNotificationResponse(NotificationResponse response) {
    // Navigate to doses screen when notification is tapped
    if (_navigationContext != null && _navigationContext!.mounted) {
      _navigationContext!.go('/doses');
    }
  }

  /// Set the navigation context for handling notification taps.
  /// Call this from the main app widget.
  static void setNavigationContext(BuildContext context) {
    _navigationContext = context;
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

    // Get localization from the stored context
    final l10n = _navigationContext != null && _navigationContext!.mounted
        ? AppLocalizations.of(_navigationContext!)
        : null;

    for (var i = 0; i < offsets.length; i++) {
      final scheduledTime = dose.scheduledTime.subtract(
        Duration(minutes: offsets[i]),
      );
      if (scheduledTime.isBefore(now)) continue;

      String title;
      if (l10n != null) {
        title = offsets[i] == 0
            ? l10n.notificationReminderTimeFor(medicationName)
            : l10n.notificationReminderInMinutes(medicationName, offsets[i]);
      } else {
        title = offsets[i] == 0
            ? 'Time for $medicationName'
            : 'Reminder: $medicationName in ${offsets[i]} min';
      }

      String body;
      if (l10n != null) {
        body = l10n.notificationReminderBody(dose.displayDosage ?? '');
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

  Future<bool> requestPermissions() async {
    if (!_supported) return true;

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      return await androidPlugin.requestNotificationsPermission() ?? false;
    }
    return true;
  }

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) await initialize();
  }
}
