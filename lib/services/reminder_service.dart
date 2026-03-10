/// Medora - Reminder / Notification Service
///
/// Manages local notifications for medication dose reminders.
library;

import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Service for scheduling and managing medication reminders.
class ReminderService {
  ReminderService._();

  static final ReminderService _instance = ReminderService._();
  static ReminderService get instance => _instance;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  /// Initialize the notification service.
  Future<void> initialize() async {
    if (_isInitialized) return;

    tz.initializeTimeZones();

    const androidSettings =
        AndroidInitializationSettings('@drawable/ic_stat_notify');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Linux settings are required when targeting Linux
    final linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open notification',
      defaultIcon: AssetsLinuxIcon('assets/icon/medora_icon.png'),
    );

    final settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      linux: linuxSettings,
    );

    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    _isInitialized = true;
  }

  /// Handle notification tap.
  void _onNotificationResponse(NotificationResponse response) {
    // Future: Navigate to the dose schedule screen
    // The payload contains the dose ID
  }

  /// Schedule all required reminders for a specific dose log.
  ///
  /// Schedules 4 notifications: 1 hour, 30 min, 10 min before, and at the time.
  Future<void> scheduleRemindersForDose({
    required DoseLog dose,
    required String medicationName,
  }) async {
    await _ensureInitialized();

    final now = DateTime.now();
    final baseId = dose.id.hashCode;

    // Define the sequence of reminders (minutes before)
    final offsets = [60, 30, 10, 0];

    for (var i = 0; i < offsets.length; i++) {
      final minutesBefore = offsets[i];
      final scheduledTime = dose.scheduledTime.subtract(Duration(minutes: minutesBefore));

      // Don't schedule if it's in the past
      if (scheduledTime.isBefore(now)) continue;

      String title;
      if (minutesBefore == 0) {
        title = 'Time for $medicationName';
      } else {
        title = 'Reminder: $medicationName in $minutesBefore min';
      }

      await _scheduleNotification(
        id: baseId + i,
        title: title,
        body: '${dose.displayDosage ?? ""} — Tap to log your dose',
        scheduledTime: scheduledTime,
        payload: dose.id,
      );
    }
  }

  /// Internal method to schedule a single zoned notification.
  Future<void> _scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
  }) async {
    // zonedSchedule is not implemented on Web and Linux in the current version of the plugin.
    if (kIsWeb || (!kIsWeb && Platform.isLinux)) {
      debugPrint('Scheduling notifications is not supported on this platform.');
      return;
    }

    final tzScheduledTime = tz.TZDateTime.from(scheduledTime, tz.local);

    const androidDetails = AndroidNotificationDetails(
      'medora_dose_reminders',
      'Dose Reminders',
      channelDescription: 'Reminders for scheduled medication doses',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Medication Reminder',
      icon: '@drawable/ic_stat_notify',
      styleInformation: BigTextStyleInformation(''),
      category: AndroidNotificationCategory.reminder,
      color: Color(0xFF2196F3), // Medora Primary Blue
      ledColor: Color(0xFF2196F3),
      ledOnMs: 1000,
      ledOffMs: 500,
      enableVibration: true,
      groupKey: 'medora_doses',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // In flutter_local_notifications v21.0.0, zonedSchedule uses only named parameters.
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

  /// Cancel all reminders associated with a specific dose.
  Future<void> cancelRemindersForDose(String doseId) async {
    await _ensureInitialized();
    final baseId = doseId.hashCode;
    // Cancel all 4 possible notification slots
    for (var i = 0; i < 4; i++) {
      await _notifications.cancel(id: baseId + i);
    }
  }

  /// Legacy method kept for backward compatibility but redirected.
  Future<void> scheduleRepeatingReminders({
    required String prescriptionId,
    required String medicationName,
    required String dosage,
    required DateTime startTime,
    required int intervalHours,
    required int durationDays,
  }) async {
    // Individual dose reminders are now handled by scheduleRemindersForDose
  }

  /// Cancel all reminders.
  Future<void> cancelAllReminders() async {
    await _notifications.cancelAll();
  }

  /// Get all pending notification requests.
  Future<List<PendingNotificationRequest>> getPendingReminders() async {
    return _notifications.pendingNotificationRequests();
  }

  /// Request notification permissions (iOS/Android 13+).
  Future<bool> requestPermissions() async {
    if (kIsWeb || (!kIsWeb && Platform.isLinux)) return true;

    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      return granted ?? false;
    }

    final iosPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (iosPlugin != null) {
      final granted = await iosPlugin.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    return true;
  }

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      await initialize();
    }
  }
}
