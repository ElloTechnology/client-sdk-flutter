// Copyright 2024 LiveKit, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@Timeout(Duration(seconds: 10))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/core/transport.dart';
import 'package:livekit_client/src/internal/events.dart';
import '../mock/e2e_container.dart';
import '../mock/peerconnection_mock.dart';

/// Disposal flips isDisposed synchronously but clears the transport's callbacks
/// from an async dispose hook. Holding that hook open keeps a test inside the
/// window where the transport is disposed yet still able to call back, which is
/// where the in-flight negotiation guards have to do the work.
class _DisposeGatedPeerConnection extends MockPeerConnection {
  final Completer<void> disposeHookGate = Completer<void>();
  bool holdDisposeHook = false;

  @override
  Future<List<RTCRtpSender>> getSenders() async {
    if (holdDisposeHook) {
      await disposeHookGate.future;
    }
    return super.getSenders();
  }

  void releaseDisposeHook() {
    if (!disposeHookGate.isCompleted) disposeHookGate.complete();
  }
}

/// Holds createOffer open so a test can dispose the transport while negotiation
/// is parked on the native round-trip.
class _GatedOfferPeerConnection extends _DisposeGatedPeerConnection {
  final Completer<void> offerRequested = Completer<void>();
  final Completer<void> offerGate = Completer<void>();
  final List<RTCSessionDescription> localDescriptions = [];

  /// Whether the gated call rejects, as a freed native connection does, rather
  /// than returning an offer.
  bool rejectOffer = false;

  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    if (!offerRequested.isCompleted) offerRequested.complete();
    await offerGate.future;
    if (rejectOffer) throw Exception('createOffer peerConnection is null');
    return super.createOffer(constraints);
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    localDescriptions.add(description);
    await super.setLocalDescription(description);
  }
}

/// Holds setLocalDescription open and then rejects it, reproducing what a closed
/// and freed native connection reports back.
class _GatedLocalDescriptionPeerConnection extends _DisposeGatedPeerConnection {
  final Completer<void> localDescriptionRequested = Completer<void>();
  final Completer<void> localDescriptionGate = Completer<void>();

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    if (!localDescriptionRequested.isCompleted) localDescriptionRequested.complete();
    await localDescriptionGate.future;
    throw Exception('setLocalDescription peerConnection is null');
  }
}

/// Rejects setLocalDescription outright, with the transport very much alive.
class _FailingLocalDescriptionPeerConnection extends MockPeerConnection {
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    throw Exception('setLocalDescription peerConnection is null');
  }
}

Future<Transport> _transportWith(MockPeerConnection pc) => Transport.create(
      (configuration, [constraints = const {}]) async => pc,
      connectOptions: const ConnectOptions(),
    );

void main() {
  // XP-3069 / Sentry LEARN-FRONTEND-J7: `NegotiationError: setLocalDescription
  // peerConnection is null`. createAndSendOffer checked isDisposed only on entry,
  // then crossed several awaits before setLocalDescription. A transport disposed
  // during the createOffer round-trip therefore applied a description to a native
  // connection that had already been closed and freed.
  group('createAndSendOffer dispose race (XP-3069)', () {
    test('aborts without touching the peer connection when disposed mid-negotiation', () async {
      final pc = _GatedOfferPeerConnection();
      final transport = await _transportWith(pc);

      var offerSent = false;
      transport.onOffer = (_) => offerSent = true;
      Object? reportedFailure;
      transport.onNegotiationFailed = (error, stackTrace) => reportedFailure = error;

      final negotiation = transport.createAndSendOffer();
      await pc.offerRequested.future;
      await transport.dispose();
      pc.offerGate.complete();

      await expectLater(negotiation, completes);
      expect(pc.localDescriptions, isEmpty);
      expect(offerSent, isFalse);
      // Teardown is expected, not a negotiation failure — it must not trigger recovery.
      expect(reportedFailure, isNull);
    });

    test('does not publish an offer whose local description was never applied', () async {
      final pc = _GatedLocalDescriptionPeerConnection();
      final transport = await _transportWith(pc);

      var offerSent = false;
      transport.onOffer = (_) => offerSent = true;
      Object? reportedFailure;
      transport.onNegotiationFailed = (error, stackTrace) => reportedFailure = error;

      final negotiation = transport.createAndSendOffer();
      await pc.localDescriptionRequested.future;

      // Dispose, but stay inside the window where the callbacks are still wired.
      pc.holdDisposeHook = true;
      final disposal = transport.dispose();
      pc.localDescriptionGate.complete();

      await expectLater(negotiation, completes);
      expect(offerSent, isFalse);
      expect(reportedFailure, isNull);

      pc.releaseDisposeHook();
      await disposal;
    });
  });

  // The debounced negotiate() fires from a timer with nobody awaiting its result,
  // so a NegotiationError used to escape as an unhandled async error and the
  // engine's negotiation-failure recovery never ran.
  group('debounced negotiate failure reporting (XP-3069)', () {
    test('reports a genuine setLocalDescription failure to onNegotiationFailed', () async {
      final transport = await _transportWith(_FailingLocalDescriptionPeerConnection());
      transport.onOffer = (_) {};

      final failure = Completer<Object>();
      transport.onNegotiationFailed = (error, stackTrace) => failure.complete(error);

      transport.negotiate(null);

      expect(await failure.future, isA<NegotiationError>());

      await transport.dispose();
    });

    test('does not report a native call that rejects because of disposal', () async {
      final pc = _GatedOfferPeerConnection()..rejectOffer = true;
      final transport = await _transportWith(pc);
      transport.onOffer = (_) {};

      Object? reportedFailure;
      transport.onNegotiationFailed = (error, stackTrace) => reportedFailure = error;

      transport.negotiate(null);
      await pc.offerRequested.future;

      // Dispose, but stay inside the window where the callbacks are still wired.
      pc.holdDisposeHook = true;
      final disposal = transport.dispose();
      pc.offerGate.complete();
      await pumpEventQueue();

      expect(reportedFailure, isNull);

      pc.releaseDisposeHook();
      await disposal;
    });
  });

  // The engine's recovery for a failed renegotiation was unreachable while the
  // error was escaping the debounced call as an unhandled async error.
  group('engine negotiation-failure wiring (XP-3069)', () {
    test('a publisher negotiation failure drives a full reconnect', () async {
      final container = E2EContainer();
      await container.connectRoom();

      final reconnectAttempt = Completer<EngineAttemptReconnectEvent>();
      container.engine.events.listen((event) {
        if (event is EngineAttemptReconnectEvent && !reconnectAttempt.isCompleted) {
          reconnectAttempt.complete(event);
        }
      });

      final onNegotiationFailed = container.engine.publisher?.onNegotiationFailed;
      expect(onNegotiationFailed, isNotNull, reason: 'engine must wire the publisher failure callback');

      onNegotiationFailed!(NegotiationError('setLocalDescription peerConnection is null'), StackTrace.current);

      await reconnectAttempt.future;
      expect(container.engine.fullReconnectOnNext, isTrue);

      await container.dispose();
    });
  });
}
