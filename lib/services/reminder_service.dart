/// Medora - Reminder / Notification Service
///
/// Manages local notifications for medication dose reminders.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

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

  /// Handle notification tap.
  void _onNotificationResponse(NotificationResponse response) {
    // Future: Navigate to the dose schedule screen
    // The payload contains the prescription ID
  }

  /// Schedule a dose reminder at a specific time.
  ///
  /// [id] - Unique notification ID (use hashCode of dose log ID).
  /// [title] - Notification title (e.g., 'Time to take Ibuprofen').
  /// [body] - Notification body (e.g., '400mg - Flu Treatment').
  /// [scheduledTime] - When to show the notification.
  /// [payload] - Optional data (e.g., prescription ID).
  Future<void> scheduleDoseReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
  }) async {
    await _ensureInitialized();

    final tzScheduledTime = tz.TZDateTime.from(scheduledTime, tz.local);

    // Don't schedule notifications in the past
    if (tzScheduledTime.isBefore(tz.TZDateTime.now(tz.local))) {
      return;
    }

    const androidDetails = AndroidNotificationDetails(
      'medora_dose_reminders',
      'Dose Reminders',
      channelDescription: 'Reminders for scheduled medication doses',
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'Medication Reminder',
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
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

  /// Schedule repeating reminders for a prescription.
  ///
  /// Generates individual notifications for each dose time.
  Future<void> scheduleRepeatingReminders({
    required String prescriptionId,
    required String medicationName,
    required String dosage,
    required DateTime startTime,
    required int intervalHours,
    required int durationDays,
  }) async {
    await _ensureInitialized();

    final endTime = startTime.add(Duration(days: durationDays));
    var currentTime = startTime;
    var notificationId = prescriptionId.hashCode;

    while (currentTime.isBefore(endTime)) {
      await scheduleDoseReminder(
        id: notificationId,
        title: 'Time to take $medicationName',
        body: '$dosage — Tap to log your dose',
        scheduledTime: currentTime,
        payload: prescriptionId,
      );

      currentTime = currentTime.add(Duration(hours: intervalHours));
      notificationId++;
    }
  }

  /// Cancel a specific reminder by ID.
  Future<void> cancelReminder(int id) async {
    await _notifications.cancel(id: id);
  }

  /// Cancel all reminders for a prescription.
  ///
  /// Cancels notifications with IDs starting from the prescription hashCode.
  Future<void> cancelPrescriptionReminders({
    required String prescriptionId,
    required int totalDoses,
  }) async {
    final startId = prescriptionId.hashCode;
    for (var i = 0; i < totalDoses; i++) {
      await _notifications.cancel(id: startId + i);
    }
  }

  /// Reschedule reminders for a prescription.
  Future<void> rescheduleReminder({
    required String prescriptionId,
    required String medicationName,
    required String dosage,
    required DateTime startTime,
    required int intervalHours,
    required int durationDays,
  }) async {
    // Cancel existing reminders
    final totalDoses =
        (durationDays * 24 / intervalHours).ceil();
    await cancelPrescriptionReminders(
      prescriptionId: prescriptionId,
      totalDoses: totalDoses,
    );

    // Schedule new ones
    await scheduleRepeatingReminders(
      prescriptionId: prescriptionId,
      medicationName: medicationName,
      dosage: dosage,
      startTime: startTime,
      intervalHours: intervalHours,
      durationDays: durationDays,
    );
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
    // Android
    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      return granted ?? false;
    }

    // iOS
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
