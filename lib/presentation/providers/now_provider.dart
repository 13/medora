/// Medora - The injectable clock, as a provider.
///
/// Its own file on purpose: almost every screen and provider needs "now", and
/// `providers.dart` — which wires the datasources, repositories and services —
/// would otherwise be pulled into leaves that want nothing else from it. Two
/// of those leaves (`app_update_provider.dart`, `settings_providers.dart`) are
/// themselves imported *by* `providers.dart`, so the dependency ran both ways.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/clock.dart';

/// Injectable clock. Screens/providers that need "now" read
/// `ref.read(nowProvider)()`; tests and goldens override it.
final nowProvider = Provider<Now>((_) => systemNow);
