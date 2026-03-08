/// Medora - Connectivity Service
///
/// Monitors network connectivity and exposes an online/offline stream.
library;

import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  ConnectivityService._();

  static final ConnectivityService instance = ConnectivityService._();

  final Connectivity _connectivity = Connectivity();
  final _controller = StreamController<bool>.broadcast();

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  /// Stream of connectivity status (true = online, false = offline).
  Stream<bool> get onlineStream => _controller.stream;

  /// Initialize and start listening to connectivity changes.
  Future<void> initialize() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _isOnline = _isConnected(result);
    } catch (e) {
      debugPrint('⚠ Connectivity check failed: $e');
      // Default to online if check fails (e.g. DBus issues on Linux)
      _isOnline = true;
    }
    
    _controller.add(_isOnline);

    _connectivity.onConnectivityChanged.listen((result) {
      final nowOnline = _isConnected(result);
      if (nowOnline != _isOnline) {
        _isOnline = nowOnline;
        _controller.add(_isOnline);
      }
    }, onError: (e) {
      debugPrint('⚠ Connectivity stream error: $e');
    });
  }

  bool _isConnected(List<ConnectivityResult> results) {
    // If we're on desktop and get an error or empty list, assume online for now
    // to avoid blocking app functionality.
    if (results.isEmpty && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      return true;
    }
    
    return results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn);
  }

  void dispose() {
    _controller.close();
  }
}
