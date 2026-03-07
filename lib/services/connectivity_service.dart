/// Medora - Connectivity Service
///
/// Monitors network connectivity and exposes an online/offline stream.
library;

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

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
    final result = await _connectivity.checkConnectivity();
    _isOnline = _isConnected(result);
    _controller.add(_isOnline);

    _connectivity.onConnectivityChanged.listen((result) {
      final nowOnline = _isConnected(result);
      if (nowOnline != _isOnline) {
        _isOnline = nowOnline;
        _controller.add(_isOnline);
      }
    });
  }

  bool _isConnected(List<ConnectivityResult> results) {
    return results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet);
  }

  void dispose() {
    _controller.close();
  }
}

