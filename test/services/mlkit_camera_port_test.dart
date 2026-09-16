/// Unit tests for the camera behind [CameraControllerPort].
///
/// The port is the one place `camera` is bound to the scanner, so the
/// widget tests' [FakeCamera] cannot cover its cancellation rules: leaving
/// the scanner while the camera is still opening has to release the
/// controller the port created, or the camera stays lit for a screen that
/// no longer exists. The controller is faked by subclassing
/// [CameraController] and overriding every method that would reach the
/// platform, and the camera list is a constructor seam.
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/mlkit_scanner_ports.dart';

const _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

const _front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

/// A [CameraController] that never reaches the platform.
class _FakeController extends CameraController {
  _FakeController(CameraDescription camera, {this.gate, this.failsToOpen})
    : super(camera, ResolutionPreset.low, enableAudio: false);

  /// Held until completed, so a test can abandon an opening camera.
  final Completer<void>? gate;

  /// The error [initialize] throws instead of opening.
  final Object? failsToOpen;

  int initializeCalls = 0;
  int disposeCalls = 0;
  int focusModeCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (gate != null) await gate!.future;
    final failure = failsToOpen;
    if (failure != null) throw failure;
    value = value.copyWith(
      isInitialized: true,
      previewSize: const Size(1920, 1080),
    );
  }

  @override
  Future<void> setFocusMode(FocusMode mode) async => focusModeCalls++;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    // Before the notifier is disposed: its setter asserts otherwise.
    value = value.copyWith(isInitialized: false);
    // The real one reaches the platform only for a camera it opened, which
    // this fake never does, so this is just the ChangeNotifier teardown.
    await super.dispose();
  }
}

void main() {
  group('CameraControllerPort', () {
    test('opens the back camera and reports it ready', () async {
      late _FakeController controller;
      final port = CameraControllerPort(
        listCameras: () async => const [_front, _back],
        createController: (camera) => controller = _FakeController(camera),
      );

      expect(await port.initialize(), isTrue);
      expect(controller.description, _back);
      expect(port.isReady, isTrue);
      expect(port.previewSize, const Size(1920, 1080));
      expect(controller.focusModeCalls, 1);

      await port.dispose();
      expect(controller.disposeCalls, 1);
      expect(port.isReady, isFalse);
    });

    test('reports no camera without opening one', () async {
      var created = 0;
      final port = CameraControllerPort(
        listCameras: () async => const <CameraDescription>[],
        createController: (camera) {
          created++;
          return _FakeController(camera);
        },
      );

      expect(await port.initialize(), isFalse);
      expect(created, 0);
      expect(port.isReady, isFalse);
    });

    test('a camera abandoned while it is listed is never opened', () async {
      final listed = Completer<void>();
      var created = 0;
      final port = CameraControllerPort(
        listCameras: () async {
          await listed.future;
          return const [_back];
        },
        createController: (camera) {
          created++;
          return _FakeController(camera);
        },
      );

      // The screen is popped while `availableCameras()` is still pending.
      final opening = port.initialize();
      await port.dispose();
      listed.complete();

      expect(await opening, isFalse);
      expect(created, 0, reason: 'nothing left to release the camera');
      expect(port.isReady, isFalse);
    });

    test('a camera abandoned while it opens is released', () async {
      final opened = Completer<void>();
      late _FakeController controller;
      final port = CameraControllerPort(
        listCameras: () async => const [_back],
        createController: (camera) =>
            controller = _FakeController(camera, gate: opened),
      );

      // The screen is popped while `controller.initialize()` is pending.
      final opening = port.initialize();
      await pumpEventQueue();
      await port.dispose();
      opened.complete();

      expect(await opening, isFalse);
      expect(controller.disposeCalls, 1);
      expect(port.isReady, isFalse);
    });

    test('an overtaken opening releases its own camera', () async {
      final opened = Completer<void>();
      final controllers = <_FakeController>[];
      final port = CameraControllerPort(
        listCameras: () async => const [_back],
        createController: (camera) {
          final controller = _FakeController(
            camera,
            gate: controllers.isEmpty ? opened : null,
          );
          controllers.add(controller);
          return controller;
        },
      );

      final first = port.initialize();
      await pumpEventQueue();
      expect(await port.initialize(), isTrue);
      opened.complete();

      expect(await first, isFalse);
      expect(controllers, hasLength(2));
      expect(controllers.first.disposeCalls, 1);
      expect(controllers.last.disposeCalls, 0);
      expect(port.isReady, isTrue);

      await port.dispose();
      expect(controllers.last.disposeCalls, 1);
    });

    test('a camera that fails to open is released and the error escapes', () {
      late _FakeController controller;
      final port = CameraControllerPort(
        listCameras: () async => const [_back],
        createController: (camera) => controller = _FakeController(
          camera,
          failsToOpen: CameraException('denied', 'no permission'),
        ),
      );

      expect(port.initialize(), throwsA(isA<CameraException>()));
      return pumpEventQueue().then((_) {
        expect(controller.disposeCalls, 1);
        expect(port.isReady, isFalse);
      });
    });
  });
}
