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
import 'package:livekit_client/src/core/engine.dart';
import 'package:livekit_client/src/core/signal_client.dart';
import 'package:livekit_client/src/core/transport.dart';
import 'package:livekit_client/src/internal/events.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
import '../mock/datachannel_mock.dart';
import '../mock/peerconnection_mock.dart';
import '../mock/websocket_mock.dart';

// Gates model native replies that arrive after retirement. The invariant is
// that only the current, undisposed publisher can make readiness succeed;
// these tests pin specific state transitions, not all possible schedules.
class _GatedStatePeerConnection extends MockPeerConnection {
  final stateRequested = Completer<void>();
  final stateReply = Completer<RTCPeerConnectionState?>();
  final disposeGate = Completer<void>();
  bool holdDisposal = false;
  int stateReads = 0;
  int offers = 0;
  final List<RTCDataChannelMessage> sent = [];

  @override
  Future<RTCPeerConnectionState?> getConnectionState() {
    stateReads++;
    if (!stateRequested.isCompleted) stateRequested.complete();
    return stateReply.future;
  }

  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    offers++;
    return super.createOffer(constraints);
  }

  @override
  Future<List<RTCRtpSender>> getSenders() async {
    if (holdDisposal) await disposeGate.future;
    return super.getSenders();
  }

  @override
  Future<RTCDataChannel> createDataChannel(String label, RTCDataChannelInit dataChannelDict) async {
    return MockDataChannel(dataChannelDict.id, label)..onMessageSend = sent.add;
  }
}

final _reset = isA<ConnectException>()
    .having((error) => error.message, 'message', 'Publisher connection reset')
    .having((error) => error.reason, 'reason', ConnectionErrorReason.InternalError);

const _connected = RTCPeerConnectionState.RTCPeerConnectionStateConnected;
const _new = RTCPeerConnectionState.RTCPeerConnectionStateNew;

Future<Transport> _transportWith(MockPeerConnection pc) => Transport.create(
      (configuration, [constraints = const {}]) async => pc,
      connectOptions: const ConnectOptions(),
    );

// Drive the real join handler and await its public completion event. This also
// configures subscriber-primary sending, so cancellation is observed at the
// sendDataPacket caller rather than only at the readiness helper.
Future<Engine> _engineWith(_GatedStatePeerConnection pc) async {
  var created = 0;
  final connector = MockWebSocketConnector();
  final client = SignalClient(connector.connect);
  addTearDown(client.dispose);
  final engine = Engine(
    signalClient: client,
    connectOptions: const ConnectOptions(),
    roomOptions: const RoomOptions(),
    peerConnectionCreate: (configuration, [constraints = const {}]) async => created++ == 0 ? pc : MockPeerConnection(),
  );
  addTearDown(engine.dispose);
  await client.connect('wss://example.test', 'test-token',
      connectOptions: const ConnectOptions(), roomOptions: const RoomOptions());
  final joined = engine.events.waitFor<EngineJoinResponseEvent>(duration: const Duration(seconds: 2));
  connector.onData(lk_rtc.SignalResponse(join: lk_rtc.JoinResponse(subscriberPrimary: true)).writeToBuffer());
  await joined;
  return engine;
}

Future<void> _send(Engine engine) =>
    engine.sendDataPacket(lk_models.DataPacket(user: lk_models.UserPacket(payload: [1])));

void main() {
  group('publisher readiness', () {
    test('sends through a connected publisher', () async {
      final pc = _GatedStatePeerConnection()..stateReply.complete(_connected);
      final engine = await _engineWith(pc);

      await _send(engine);

      expect(pc.sent, hasLength(1));
      expect(pc.stateReads, 1);
      expect(pc.offers, 0);
    });

    test('rejects a disposed publisher before native work or sending', () async {
      final pc = _GatedStatePeerConnection()..stateReply.complete(_new);
      final engine = await _engineWith(pc);
      await engine.publisher!.dispose();

      await expectLater(_send(engine), throwsA(_reset));

      expect(pc.stateReads, 0);
      expect(pc.offers, 0);
      expect(pc.sent, isEmpty);
    });

    test('rejects sending after disconnect while its publisher remains alive', () async {
      final pc = _GatedStatePeerConnection()..stateReply.complete(_connected);
      final engine = await _engineWith(pc);
      await engine.disconnect();
      expect(engine.publisher!.isDisposed, isFalse);

      await expectLater(_send(engine), throwsA(_reset));

      expect(pc.stateReads, 0);
      expect(pc.sent, isEmpty);
    });

    test('cancels a pending native reply after disconnect', () async {
      final pc = _GatedStatePeerConnection();
      final engine = await _engineWith(pc);
      final result = expectLater(_send(engine), throwsA(_reset));
      await pc.stateRequested.future;
      await engine.disconnect();
      expect(engine.publisher!.isDisposed, isFalse);

      pc.stateReply.complete(_connected);
      await result;

      expect(pc.sent, isEmpty);
    });

    test('rejects sending after cleanup', () async {
      final pc = _GatedStatePeerConnection();
      final engine = await _engineWith(pc);
      await engine.cleanUp();

      await expectLater(_send(engine), throwsA(_reset));

      expect(pc.stateReads, 0);
      expect(pc.sent, isEmpty);
    });

    for (final state in [_connected, _new]) {
      test('rejects a $state reply after disposal begins', () async {
        final pc = _GatedStatePeerConnection()..holdDisposal = true;
        final engine = await _engineWith(pc);
        final result = expectLater(_send(engine), throwsA(_reset));
        await pc.stateRequested.future;
        final disposal = engine.publisher!.dispose();
        addTearDown(() async {
          pc.disposeGate.complete();
          await disposal;
        });

        pc.stateReply.complete(state);
        await result;

        expect(pc.offers, 0);
        expect(pc.sent, isEmpty);
      });
    }

    test('cancels a native error after disposal begins', () async {
      final pc = _GatedStatePeerConnection()..holdDisposal = true;
      final engine = await _engineWith(pc);
      final result = expectLater(_send(engine), throwsA(_reset));
      await pc.stateRequested.future;
      final disposal = engine.publisher!.dispose();
      addTearDown(() async {
        pc.disposeGate.complete();
        await disposal;
      });

      pc.stateReply.completeError(StateError('peerConnection is null'));
      await result;

      expect(pc.offers, 0);
      expect(pc.sent, isEmpty);
    });

    test('preserves the live native error and stack for every caller', () async {
      final pc = _GatedStatePeerConnection();
      final engine = await _engineWith(pc);
      final error = StateError('peerConnection is null');
      final stack = StackTrace.fromString('native getConnectionState stack');
      final first =
          _send(engine).then<Object?>((_) => null, onError: (Object error, StackTrace stack) => (error, stack));
      final second = engine
          .ensurePublisherConnected()
          .then<Object?>((_) => null, onError: (Object error, StackTrace stack) => (error, stack));
      await pc.stateRequested.future;

      pc.stateReply.completeError(error, stack);

      expect(await first, (error, stack));
      expect(await second, (error, stack));
      expect(pc.stateReads, 1);
      expect(pc.sent, isEmpty);
    });

    test('rejects a successful reply from a replaced publisher', () async {
      final pc = _GatedStatePeerConnection();
      final engine = await _engineWith(pc);
      final oldTransport = engine.publisher!;
      addTearDown(oldTransport.dispose);
      final result = expectLater(_send(engine), throwsA(_reset));
      await pc.stateRequested.future;
      final replacement = _GatedStatePeerConnection();
      engine.publisher = await _transportWith(replacement);

      pc.stateReply.complete(_new);
      await result;

      expect(pc.sent, isEmpty);
      expect(replacement.offers, 0);
      expect(replacement.stateReads, 0);
    });

    test('cancels a native error from a replaced publisher', () async {
      final pc = _GatedStatePeerConnection();
      final engine = await _engineWith(pc);
      addTearDown(engine.publisher!.dispose);
      final result = expectLater(_send(engine), throwsA(_reset));
      await pc.stateRequested.future;
      engine.publisher = await _transportWith(MockPeerConnection());

      pc.stateReply.completeError(StateError('peerConnection is null'));
      await result;

      expect(pc.sent, isEmpty);
    });

    test('cleanup settles concurrent callers before native disposal finishes', () async {
      final pc = _GatedStatePeerConnection()..holdDisposal = true;
      final engine = await _engineWith(pc);
      final first = expectLater(_send(engine), throwsA(_reset));
      final second = expectLater(engine.ensurePublisherConnected(), throwsA(_reset));
      await pc.stateRequested.future;
      final cleanup = engine.cleanUp();
      addTearDown(() async {
        pc.disposeGate.complete();
        await cleanup;
      });

      await Future.wait([first, second]);
      // A late native failure must not produce a second unhandled future error.
      pc.stateReply.completeError(StateError('peerConnection is null'));
      await pumpEventQueue();

      expect(pc.stateReads, 1);
      expect(pc.sent, isEmpty);
    });

    test('old success leaves replacement readiness pending and shared', () async {
      final pc = _GatedStatePeerConnection();
      final engine = await _engineWith(pc);
      addTearDown(engine.publisher!.dispose);
      final oldResult = expectLater(_send(engine), throwsA(_reset));
      await pc.stateRequested.future;
      final replacement = _GatedStatePeerConnection();
      engine.publisher = await _transportWith(replacement);
      final ready = engine.ensurePublisherConnected();
      var completed = false;
      final result = ready.then((_) => completed = true);
      await replacement.stateRequested.future;

      pc.stateReply.complete(_connected);
      await oldResult;
      await pumpEventQueue();

      expect(completed, isFalse);
      expect(engine.ensurePublisherConnected(), same(ready));
      expect(replacement.stateReads, 1);
      expect(pc.sent, isEmpty);
      replacement.stateReply.complete(_connected);
      await result;
    });

    test('old failure leaves replacement readiness pending and shared', () async {
      final pc = _GatedStatePeerConnection();
      final engine = await _engineWith(pc);
      addTearDown(engine.publisher!.dispose);
      final oldResult = expectLater(_send(engine), throwsA(_reset));
      await pc.stateRequested.future;
      final replacement = _GatedStatePeerConnection();
      engine.publisher = await _transportWith(replacement);
      final ready = engine.ensurePublisherConnected();
      var completed = false;
      final result = ready.then((_) => completed = true);
      await replacement.stateRequested.future;

      pc.stateReply.completeError(StateError('peerConnection is null'));
      await oldResult;
      await pumpEventQueue();

      expect(completed, isFalse);
      expect(engine.ensurePublisherConnected(), same(ready));
      expect(replacement.stateReads, 1);
      expect(pc.sent, isEmpty);
      replacement.stateReply.complete(_connected);
      await result;
    });
  });

  group('inbound RPC while the publisher retires', () {
    // The SDK acks and answers an agent's RPC inside its own engine listener,
    // and both sends wait for publisher readiness. A teardown that retires the
    // publisher mid-wait fails that readiness; the reset must end the request
    // rather than escape the listener into the host application's zone, where
    // an integration test (or the app's crash handler) sees it as uncaught.
    test('ends a request whose ack waits on the retired publisher', () async {
      final pc = _GatedStatePeerConnection();
      final zoneErrors = <Object>[];
      var handled = false;

      await runZonedGuarded(() async {
        final engine = await _engineWith(pc);
        final room = Room(engine: engine);
        addTearDown(room.dispose);
        room.registerRpcMethod('echo', (data) async {
          handled = true;
          return data.payload;
        });

        engine.events.emit(EngineRPCRequestReceivedEvent(
          request: lk_models.RpcRequest(
            id: 'request-1',
            method: 'echo',
            payload: 'hello',
            responseTimeoutMs: 1000,
            version: 1,
          ),
          identity: 'agent',
        ));
        await pc.stateRequested.future;
        await engine.cleanUp();
        await pumpEventQueue();
      }, (error, _) => zoneErrors.add(error));

      expect(zoneErrors, isEmpty);
      expect(handled, isFalse);
      expect(pc.sent, isEmpty);
    });

    test('still raises a live ack failure', () async {
      final zoneErrors = <Object>[];

      await runZonedGuarded(() async {
        // Created inside the guarded zone: a future does not deliver its error
        // across error zones, so a native reply created outside would report
        // its failure to the test's zone instead of the listener's.
        final pc = _GatedStatePeerConnection();
        final engine = await _engineWith(pc);
        final room = Room(engine: engine);
        addTearDown(room.dispose);

        engine.events.emit(EngineRPCRequestReceivedEvent(
          request: lk_models.RpcRequest(
            id: 'request-1',
            method: 'echo',
            payload: 'hello',
            responseTimeoutMs: 1000,
            version: 1,
          ),
          identity: 'agent',
        ));
        await pc.stateRequested.future;
        pc.stateReply.completeError(StateError('peerConnection is null'));
        await pumpEventQueue();
      }, (error, _) => zoneErrors.add(error));

      expect(zoneErrors, [isA<StateError>()]);
    });
  });
}
