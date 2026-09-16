/// Medora - The identity of a scheduled dose.
///
/// A generated dose's id is derived from its prescription and its time, so
/// every device that generates the same schedule creates the same rows, and
/// the server's copy of a dose (taken or skipped elsewhere) is recognised
/// as the same dose.
library;

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// [time] to the minute, from its own date and time fields: the key two
/// copies of one scheduled dose share.
String doseSlotKey(DateTime time) =>
    '${time.year}-${_two(time.month)}-${_two(time.day)}'
    'T${_two(time.hour)}:${_two(time.minute)}';

/// The id of [prescriptionId]'s dose scheduled at [time] (UUID v5).
String scheduledDoseId(String prescriptionId, DateTime time) =>
    _uuid.v5(Namespace.url.value, '$prescriptionId-${doseSlotKey(time)}');

String _two(int n) => n.toString().padLeft(2, '0');
