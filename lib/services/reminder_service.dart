/// Medora - Reminder / Notification Service
///
/// Manages local notifications for medication dose reminders.
library;

import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:go_router/go_router.dart';

/// Service for scheduling and managing medication reminders.
class ReminderService {
  ReminderService._();

  static final ReminderService _instance = ReminderService._();
  static ReminderService get instance => _instance;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  // Store navigation callback
  static BuildContext? _navigationContext;

  /// Initialize the notification service.
  Future<void> initialize() async {
    if (_isInitialized) return;

    // USE latest.dart INSTEAD OF latest_all.dart
    // This significantly reduces startup time and memory usage.
    tz.initializeTimeZones();

    const androidSettings =
        AndroidInitializationSettings('ic_stat_notify');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    final settings = InitializationSettings(
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

  /// Schedule reminders for a dose.
  Future<void> scheduleRemindersForDose({
    required DoseLog dose,
    required String medicationName,
    bool cancelFirst = true,
  }) async {
    if (kIsWeb || (!kIsWeb && Platform.isLinux)) return;
    
    await _ensureInitialized();

    if (cancelFirst) {
      await cancelRemindersForDose(dose.id);
    }

    final now = DateTime.now();
    final baseId = dose.id.hashCode;
    final offsets = [60, 0];

    // Get localization from the stored context
    final l10n = _navigationContext != null && _navigationContext!.mounted
        ? AppLocalizations.of(_navigationContext!)
        : null;

    for (var i = 0; i < offsets.length; i++) {
      final scheduledTime = dose.scheduledTime.subtract(Duration(minutes: offsets[i]));
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
        body = l10n.notificationReminderBody(dose.displayDosage ?? "");
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
    if (kIsWeb || (!kIsWeb && Platform.isLinux)) return;

    final tzScheduledTime = tz.TZDateTime.from(scheduledTime, tz.local);

    final androidDetails = AndroidNotificationDetails(
      'medora_dose_reminders',
      l10n?.notificationChannelName ?? 'Dose Reminders',
      channelDescription: l10n?.notificationChannelDescription ?? 'Reminders for scheduled medication doses',
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

  Future<void> cancelRemindersForDose(String doseId) async {
    if (kIsWeb || (!kIsWeb && Platform.isLinux)) return;
    await _ensureInitialized();
    final baseId = doseId.hashCode;
    for (var i = 0; i < 4; i++) {
      await _notifications.cancel(id: baseId + i);
    }
  }

  Future<void> cancelAllReminders() async {
    await _notifications.cancelAll();
  }

  Future<bool> requestPermissions() async {
    if (kIsWeb || (!kIsWeb && Platform.isLinux)) return true;

    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      return await androidPlugin.requestNotificationsPermission() ?? false;
    }
    return true;
  }

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) await initialize();
  }
}
