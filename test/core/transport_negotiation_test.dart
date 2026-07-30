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
import '../mock/peerconnection_mock.dart';

/// Holds createOffer open so a test can dispose the transport while negotiation
/// is parked on the native round-trip.
class _GatedOfferPeerConnection extends MockPeerConnection {
  final Completer<void> offerRequested = Completer<void>();
  final Completer<void> offerGate = Completer<void>();
  final List<RTCSessionDescription> localDescriptions = [];

  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    offerRequested.complete();
    await offerGate.future;
    return super.createOffer(constraints);
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    localDescriptions.add(description);
    await super.setLocalDescription(description);
  }
}

/// Reproduces what a closed and freed native peer connection reports back.
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
  });
}
