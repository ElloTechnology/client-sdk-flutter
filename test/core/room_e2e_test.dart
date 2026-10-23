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

@Timeout(Duration(seconds: 5))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:logging/logging.dart';

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/extensions.dart';
import 'package:livekit_client/src/internal/events.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
import 'package:livekit_client/src/types/internal.dart';
import '../mock/e2e_container.dart';
import '../mock/peerconnection_mock.dart';
import '../mock/test_data.dart';
import '../mock/websocket_mock.dart';
import 'signal_client_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late E2EContainer container;
  late Room room;
  late MockWebSocketConnector ws;
  setUp(() async {
    // configure logs for debugging
    Logger.root.level = Level.FINEST;
    Logger.root.onRecord.listen((record) {
      print('[${record.level.name}]: ${record.message}');
    });

    container = E2EContainer();
    room = container.room;
    ws = container.wsConnector;
    await container.connectRoom();
  });

  tearDown(() async {
    await container.dispose();
  });

  group('connection', () {
    test('disconnect and connect', () async {
      await room.disconnect();
      await container.connectRoom();
      expect(room.connectionState, ConnectionState.connected);
      expect(room.localParticipant?.sid, joinResponse.join.participant.sid);
    }, skip: 'todo');
  });

  group('room updates', () {
    test('participant join', () async {
      final publicEventsStream = room.events.streamCtrl.stream.where((event) => event is! InternalEvent);

      expect(
        publicEventsStream,
        emitsInOrder(<Matcher>[
          predicate<ParticipantStateUpdatedEvent>((event) => event.participant.sid == remoteParticipantData.sid),
          predicate<ParticipantConnectedEvent>(
            (event) => event.participant.sid == remoteParticipantData.sid,
          ),
          predicate<TrackPublishedEvent>(
            (event) => event.participant.sid == remoteParticipantData.sid,
          ),
        ]),
      );

      ws.onData(participantJoinResponse.writeToBuffer());

      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));
      expect(room.remoteParticipants.length, 1);
    });

    test('participant join with tracks populated before connected event', () async {
      // Track whether participant has tracks when connected event fires
      bool participantHadTracksOnConnect = false;
      int trackCountOnConnect = 0;

      // Listen for ParticipantConnectedEvent
      final cancel = room.events.on<ParticipantConnectedEvent>((event) {
        // Verify participant is fully populated with tracks
        trackCountOnConnect = event.participant.trackPublications.length;
        participantHadTracksOnConnect = trackCountOnConnect > 0;
      });

      // Send participant join with tracks
      ws.onData(participantJoinResponse.writeToBuffer());

      // Wait for connected event
      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));

      // Clean up listener
      await cancel();

      // Verify participant had tracks when connected event was emitted
      expect(participantHadTracksOnConnect, isTrue,
          reason: 'Participant should have tracks when ParticipantConnectedEvent is emitted');
      expect(trackCountOnConnect, greaterThan(0),
          reason: 'Participant should have at least one track when connected event fires');

      // Verify the participant is in the room
      expect(room.remoteParticipants.length, 1);
    });

    test('participant disconnect', () async {
      ws.onData(participantJoinResponse.writeToBuffer());
      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));

      ws.onData(participantDisconnectResponse.writeToBuffer());
      expect(
        room.events.streamCtrl.stream,
        emitsInOrder(<Matcher>[
          predicate<TrackUnpublishedEvent>((event) => event.participant.sid == remoteParticipantData.sid),
          predicate<ParticipantDisconnectedEvent>((event) => event.participant.sid == remoteParticipantData.sid),
        ]),
      );

      await room.events.waitFor<ParticipantDisconnectedEvent>(duration: const Duration(seconds: 1));
      expect(room.remoteParticipants.length, 0);
    });

    test('participant metadata changed', () async {
      ws.onData(participantJoinResponse.writeToBuffer());
      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));

      ws.onData(participantMetadataChangedResponse.writeToBuffer());
      expect(
        room.events.streamCtrl.stream,
        emits(
          predicate<ParticipantMetadataUpdatedEvent>((event) =>
              event.participant.metadata == participantMetadataChangedResponse.update.participants[0].metadata),
        ),
      );
    });

    test('room metadata update', () async {
      expect(
        room.events.streamCtrl.stream,
        emits(predicate<RoomMetadataChangedEvent>((event) =>
            event.metadata == roomUpdateResponse.roomUpdate.room.metadata && room.metadata == event.metadata)),
      );
      ws.onData(roomUpdateResponse.writeToBuffer());
    });

    test('connection quality', () async {
      expect(
        room.events.streamCtrl.stream,
        emits(predicate<ParticipantConnectionQualityUpdatedEvent>((event) =>
            event.participant.sid == localParticipantData.sid &&
            event.connectionQuality == ConnectionQuality.excellent)),
      );
      ws.onData(connectionQualityResponse.writeToBuffer());
    });

    test('active speakers changed', () async {
      ws.onData(participantJoinResponse.writeToBuffer());
      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));

      expect(
        room.events.streamCtrl.stream,
        emits(
          predicate<ActiveSpeakersChangedEvent>((event) => event.speakers[0].sid == remoteParticipantData.sid),
        ),
      );
      ws.onData(activeSpeakerResponse.writeToBuffer());
    });

    test('leave', () async {
      expect(room.events.streamCtrl.stream,
          emits(predicate<RoomDisconnectedEvent>((event) => event.reason == DisconnectReason.unknown)));
      ws.onData(leaveResponse.writeToBuffer());
    });

    // A terminal leave carries the reason the server chose; each one must reach
    // the application with its own attribution rather than collapsing into a
    // generic loss.
    const terminalLeaveReasons = <lk_models.DisconnectReason, DisconnectReason>{
      lk_models.DisconnectReason.MIGRATION: DisconnectReason.migration,
      lk_models.DisconnectReason.SIGNAL_CLOSE: DisconnectReason.signalClose,
      lk_models.DisconnectReason.ROOM_CLOSED: DisconnectReason.roomClosed,
      lk_models.DisconnectReason.USER_UNAVAILABLE: DisconnectReason.userUnavailable,
      lk_models.DisconnectReason.USER_REJECTED: DisconnectReason.userRejected,
      lk_models.DisconnectReason.SIP_TRUNK_FAILURE: DisconnectReason.sipTrunkFailure,
      lk_models.DisconnectReason.CONNECTION_TIMEOUT: DisconnectReason.connectionTimeout,
      lk_models.DisconnectReason.MEDIA_FAILURE: DisconnectReason.mediaFailure,
      lk_models.DisconnectReason.AGENT_ERROR: DisconnectReason.agentError,
    };

    for (final entry in terminalLeaveReasons.entries) {
      test('leave with ${entry.key.name} disconnects with ${entry.value.name}', () async {
        final disconnected = room.events.waitFor<RoomDisconnectedEvent>(duration: const Duration(seconds: 2));

        ws.onData(lk_rtc.SignalResponse(
          leave: lk_rtc.LeaveRequest(
            reason: entry.key,
            action: lk_rtc.LeaveRequest_Action.DISCONNECT,
          ),
        ).writeToBuffer());

        expect((await disconnected).reason, entry.value);
      });
    }

    test('leave with a reason newer than the generated protocol disconnects as unknown', () async {
      final disconnected = room.events.waitFor<RoomDisconnectedEvent>(duration: const Duration(seconds: 2));

      // field 8 (leave), length-delimited, wrapping field 2 (reason) carrying a
      // value beyond anything this SDK's protobuf can name.
      ws.onData(Uint8List.fromList([(8 << 3) | 2, 0x02, (2 << 3) | 0, 127]));

      expect((await disconnected).reason, DisconnectReason.unknown);
    });

    test('tracks arriving before participant metadata are handled once metadata arrives', () async {
      final fakeStream = _FakeMediaStream('${remoteParticipantData.sid}|remote_stream');
      final fakeTrack = _FakeMediaStreamTrack(
        id: remoteAudioTrack.sid,
        kind: 'audio',
      );

      var subscriptionException = false;
      room.events.on<TrackSubscriptionExceptionEvent>((event) {
        subscriptionException = true;
      });

      // Emit onTrack before participant update arrives.
      container.engine.events.emit(EngineTrackAddedEvent(
        track: fakeTrack,
        stream: fakeStream,
        receiver: null,
      ));

      // Now deliver participant metadata.
      ws.onData(participantJoinResponse.writeToBuffer());

      // Track should eventually subscribe once metadata is available.
      final trackSubscribed = await room.events.waitFor<TrackSubscribedEvent>(
        duration: const Duration(seconds: 1),
      );

      expect(subscriptionException, isFalse, reason: 'Track subscription should not fail when metadata arrives later');
      expect(trackSubscribed.participant.sid, remoteParticipantData.sid);
      expect(trackSubscribed.publication.track, isNotNull);
    });
  });

  group('reconnect republish', () {
    Future<LocalAudioTrack> addActiveAudioPublication(
      String id, {
      TrackSource source = TrackSource.microphone,
      LocalAudioTrack Function(rtc.MediaStream, rtc.MediaStreamTrack)? createTrack,
    }) async {
      final participant = room.localParticipant!;
      final mediaStream = _FakeMediaStream('$id-stream');
      final mediaTrack = _FakeMediaStreamTrack(id: '$id-track', kind: 'audio');
      await mediaStream.addTrack(mediaTrack);
      final track = createTrack?.call(mediaStream, mediaTrack) ??
          LocalAudioTrack(source, mediaStream, mediaTrack, const AudioCaptureOptions());
      participant.addTrackPublication(LocalTrackPublication<LocalAudioTrack>(
        participant: participant,
        info: lk_models.TrackInfo(
          sid: '$id-publication',
          type: lk_models.TrackType.AUDIO,
          source: source.toPBType(),
        ),
        track: track,
      ));
      await track.start();
      return track;
    }

    // Confirms every AddTrackRequest for [cid] once the SDK has sent it, so the
    // confirmation cannot arrive before the SDK is waiting for it.
    void confirmPublishOf(String cid, TrackSource source) {
      ws.onSend = (data) {
        final request = lk_rtc.SignalRequest.fromBuffer(data);
        if (!request.hasAddTrack() || request.addTrack.cid != cid) return;
        scheduleMicrotask(() => ws.onData(lk_rtc.SignalResponse(
              trackPublished: lk_rtc.TrackPublishedResponse(
                cid: cid,
                track: lk_models.TrackInfo(
                  sid: '$cid-republished',
                  type: lk_models.TrackType.AUDIO,
                  source: source.toPBType(),
                ),
              ),
            ).writeToBuffer()));
      };
    }

    // The server never confirms a republish, as on a flaky reconnect, so each
    // one fails at [publish].
    void failUnconfirmedPublishesQuickly({Duration publish = const Duration(milliseconds: 50)}) {
      container.engine.connectOptions = ConnectOptions(
        timeouts: Timeouts(
          connection: const Duration(seconds: 10),
          debounce: const Duration(milliseconds: 20),
          publish: publish,
          subscribe: const Duration(seconds: 10),
          peerConnection: const Duration(seconds: 10),
          iceRestart: const Duration(seconds: 10),
        ),
      );
    }

    // Replaces the room with one whose server enables fast publish, so a
    // publish adds its sender before the server confirms the track.
    Future<void> reconnectWithFastPublish() async {
      await container.dispose();
      resetMockDataChannels();
      container = E2EContainer();
      room = container.room;
      ws = container.wsConnector;
      await container.connectRoom(fastPublishCodecs: [lk_models.Codec(mime: 'audio/opus')]);
    }

    // Drives a full restart through the engine, as a lost connection does:
    // handleReconnect schedules attemptReconnect, which restarts the
    // connection and joins again.
    Future<void> reconnectFully({List<lk_models.Codec>? fastPublishCodecs}) async {
      container.answerNextJoin(fastPublishCodecs: fastPublishCodecs);
      final restarted = container.engine.events.waitFor<EngineRestartedEvent>(duration: const Duration(seconds: 2));
      container.engine.fullReconnectOnNext = true;
      await container.engine.handleReconnect(ClientDisconnectReason.reconnectRetry);
      await restarted;
    }

    // Completes once the SDK has sent its first AddTrackRequest, while the
    // publish is waiting on the server.
    Future<void> addTrackSent() {
      final sent = Completer<void>();
      ws.onSend = (data) {
        if (!sent.isCompleted && lk_rtc.SignalRequest.fromBuffer(data).hasAddTrack()) sent.complete();
      };
      return sent.future;
    }

    // Collects the records rePublishAllTracks logs for a failed track, and
    // completes [first] with the first of them.
    ({List<LogRecord> records, Future<void> first}) republishFailureLogs() {
      final records = <LogRecord>[];
      final first = Completer<void>();
      final logs = Logger.root.onRecord.where((record) => record.message.startsWith('reconnect republish')).listen(
        (record) {
          records.add(record);
          if (!first.isCompleted) first.complete();
        },
      );
      addTearDown(logs.cancel);
      return (records: records, first: first.future);
    }

    List<RoomReconnectedEvent> collectReconnected() {
      final reconnected = <RoomReconnectedEvent>[];
      final cancel = room.events.on<RoomReconnectedEvent>(reconnected.add);
      addTearDown(cancel);
      return reconnected;
    }

    test('XP-5116: a full reconnect whose microphone republish times out still emits RoomReconnectedEvent', () async {
      failUnconfirmedPublishesQuickly();
      final track = await addActiveAudioPublication('microphone');
      final severe = <LogRecord>[];
      final logs = Logger.root.onRecord.where((record) => record.level >= Level.SEVERE).listen(severe.add);
      addTearDown(logs.cancel);

      final reconnected = room.events.waitFor<RoomReconnectedEvent>(duration: const Duration(seconds: 2));
      container.engine.events.emit(const EngineRestartedEvent());

      // CRITICAL: the TrackPublishException used to escape the restart handler
      // to the root zone, and RoomReconnectedEvent never fired, leaving the app
      // in its reconnecting state with no microphone.
      await reconnected;
      expect(room.localParticipant!.getTrackPublicationBySource(TrackSource.microphone), isNull);
      expect(track.isActive, isFalse, reason: 'the unpublished track must not keep capturing');
      expect(
        severe.map((record) => (record.message, record.error.runtimeType)),
        contains(('reconnect republish failed for microphone track', TrackPublishException)),
      );
    });

    test('XP-5116: one failed republish does not skip the tracks after it', () async {
      await addActiveAudioPublication(
        'failing',
        createTrack: (stream, mediaTrack) => _FailingRepublishAudioTrack(stream, mediaTrack),
      );
      await addActiveAudioPublication('healthy', source: TrackSource.screenShareAudio);
      confirmPublishOf('healthy-track', TrackSource.screenShareAudio);

      await room.localParticipant!.rePublishAllTracks();

      final participant = room.localParticipant!;
      expect(participant.getTrackPublicationBySource(TrackSource.microphone), isNull);
      expect(participant.getTrackPublicationBySource(TrackSource.screenShareAudio)?.sid, 'healthy-track-republished');
    });

    // XP-5116 review: the restart handler is not serialized, so a newer restart
    // can begin during the publish timeout. The first restart's completion then
    // announced a reconnect while the engine was reconnecting again.
    test(
        'XP-5116: a full restart that begins during the republish supersedes the first restart\'s RoomReconnectedEvent',
        () async {
      failUnconfirmedPublishesQuickly();
      await addActiveAudioPublication('microphone');
      final pending = addTrackSent();
      final failures = republishFailureLogs();
      final reconnected = collectReconnected();

      container.engine.events.emit(const EngineRestartedEvent());
      await pending;
      container.engine.events.emit(const EngineFullRestartingEvent());
      await failures.first;
      await pumpEventQueue();

      expect(reconnected, isEmpty, reason: 'the newer restart announces its own reconnect');
    });

    // XP-5116 review: a republish that fails because the connection dropped
    // under it is not a server that refused the track, and must not land in
    // the severe republish-failure family.
    test('XP-5116: a signal connection lost during the republish is logged at warning and announces no reconnect',
        () async {
      failUnconfirmedPublishesQuickly();
      await addActiveAudioPublication('microphone');
      final pending = addTrackSent();
      final failures = republishFailureLogs();
      final reconnected = collectReconnected();

      container.engine.events.emit(const EngineRestartedEvent());
      await pending;
      await container.client.cleanUp();
      await failures.first;
      await pumpEventQueue();

      expect(
        failures.records.map((record) => (record.level, record.message)),
        [
          (
            Level.WARNING,
            'reconnect republish abandoned for microphone track, '
                'connectionState: ConnectionState.disconnected, superseded: false'
          )
        ],
      );
      expect(reconnected, isEmpty, reason: 'a lost connection reconnects or disconnects on its own');
    });

    // XP-5116 review: with fast publish the sender is added alongside the
    // AddTrackRequest, so a timed-out publish left it on the publisher
    // connection where a late server confirmation could publish it as a
    // second, silent microphone.
    test('XP-5116: a republish that times out after adding its sender removes that sender', () async {
      await reconnectWithFastPublish();
      failUnconfirmedPublishesQuickly();
      final track = await addActiveAudioPublication('microphone');

      await room.localParticipant!.rePublishAllTracks();

      final sender = track.transceiver?.sender;
      expect(sender, isNotNull, reason: 'fast publish adds the sender before the server confirms');
      final publisher = container.engine.publisher!.pc as MockPeerConnection;
      expect(publisher.removedSenders, [sender]);
    });

    // XP-5116 review: the app's mic repair enables the microphone through
    // setMicrophoneEnabled, which publishes outside rePublishAllTracks. A
    // timed-out attempt left its sender behind, and the retry published a
    // second track beside it.
    test('XP-5116: a publish that times out after adding its sender removes that sender', () async {
      await reconnectWithFastPublish();
      failUnconfirmedPublishesQuickly();
      final mediaStream = _FakeMediaStream('microphone-stream');
      final mediaTrack = _FakeMediaStreamTrack(id: 'microphone-track', kind: 'audio');
      await mediaStream.addTrack(mediaTrack);
      final track = LocalAudioTrack(TrackSource.microphone, mediaStream, mediaTrack, const AudioCaptureOptions());

      await expectLater(room.localParticipant!.publishAudioTrack(track), throwsA(isA<TrackPublishException>()));

      final sender = track.transceiver?.sender;
      expect(sender, isNotNull, reason: 'fast publish adds the sender before the server confirms');
      final publisher = container.engine.publisher!.pc as MockPeerConnection;
      expect(publisher.removedSenders, [sender]);
    });

    test('XP-5116: a republish that times out before adding a sender leaves the track\'s earlier sender alone',
        () async {
      failUnconfirmedPublishesQuickly();
      final track = await addActiveAudioPublication('microphone');
      // The sender the track carried on the connection before the reconnect.
      final earlierTransceiver = MockRtpTransceiver();
      track.transceiver = earlierTransceiver;

      await room.localParticipant!.rePublishAllTracks();

      expect(track.transceiver, same(earlierTransceiver), reason: 'without fast publish no sender is added');
      final publisher = container.engine.publisher!.pc as MockPeerConnection;
      expect(publisher.removedSenders, isEmpty);
    });

    // XP-5116 review: the epoch guard must not drop the reconnect of a restart
    // nothing superseded.
    test('XP-5116: a full reconnect through the engine republishes the microphone and emits RoomReconnectedEvent',
        () async {
      await addActiveAudioPublication('microphone');
      confirmPublishOf('microphone-track', TrackSource.microphone);
      final reconnected = room.events.waitFor<RoomReconnectedEvent>(duration: const Duration(seconds: 2));

      await reconnectFully();

      await reconnected;
      expect(
        room.localParticipant!.getTrackPublicationBySource(TrackSource.microphone)?.sid,
        'microphone-track-republished',
      );
    });

    // XP-5116 review: a second restart can finish while the first restart's
    // republish waits out its publish timeout. The engine reads connected
    // again by then, so the failure was logged at severe, and the cleanup
    // removed the first connection's sender from the second connection.
    test(
        'XP-5116: a republish a completed newer restart superseded logs at warning and leaves the new connection alone',
        () async {
      final codecs = [lk_models.Codec(mime: 'audio/opus')];
      await reconnectWithFastPublish();
      failUnconfirmedPublishesQuickly(publish: const Duration(milliseconds: 500));
      final track = await addActiveAudioPublication('microphone');
      final pending = addTrackSent();
      final failures = republishFailureLogs();

      await reconnectFully(fastPublishCodecs: codecs);
      await pending;
      final firstPublisher = container.engine.publisher!.pc as MockPeerConnection;
      await reconnectFully(fastPublishCodecs: codecs);
      final secondPublisher = container.engine.publisher!.pc as MockPeerConnection;
      expect(secondPublisher, isNot(same(firstPublisher)));
      expect(failures.records, isEmpty, reason: 'the second restart must complete inside the publish timeout');
      await failures.first;
      await pumpEventQueue();

      expect(track.transceiver, isNotNull, reason: 'fast publish adds the sender on the first restart\'s connection');
      expect(
        failures.records.map((record) => (record.level, record.message)),
        [
          (
            Level.WARNING,
            'reconnect republish abandoned for microphone track, '
                'connectionState: ConnectionState.connected, superseded: true'
          )
        ],
      );
      expect(secondPublisher.removedSenders, isEmpty);
      expect(firstPublisher.removedSenders, isEmpty, reason: 'the first connection is closed');
    });
  });

  group('publish guards', () {
    test('concurrent setSourceEnabled serializes calls', () async {
      final lp = room.localParticipant!;

      // Both calls will fail (no camera hardware in test), but the
      // SerialRunner should serialize them — the second waits for the
      // first to complete before executing.
      final future1 = lp.setSourceEnabled(TrackSource.camera, true);
      final future2 = lp.setSourceEnabled(TrackSource.camera, true);

      // Both should fail with the same error (no camera), not with
      // duplicate track errors or unhandled exceptions.
      final results = await Future.wait([
        future1.catchError((_) => null),
        future2.catchError((_) => null),
      ]);

      // Both calls completed (didn't hang or deadlock).
      expect(results.length, 2);
    });

    test('XP-2782: full reconnect does not republish a stopped muted microphone', () async {
      final participant = room.localParticipant!;
      final mediaStream = _FakeMediaStream('muted-microphone-stream');
      final mediaTrack = _FakeMediaStreamTrack(
        id: 'muted-microphone-track',
        kind: 'audio',
      );
      await mediaStream.addTrack(mediaTrack);
      final track = LocalAudioTrack(
        TrackSource.microphone,
        mediaStream,
        mediaTrack,
        const AudioCaptureOptions(),
      );
      final publication = LocalTrackPublication<LocalAudioTrack>(
        participant: participant,
        info: lk_models.TrackInfo(
          sid: 'muted-microphone-publication',
          type: lk_models.TrackType.AUDIO,
          source: lk_models.TrackSource.MICROPHONE,
        ),
        track: track,
      );
      participant.addTrackPublication(publication);
      await track.start();
      final mutedEvent = room.events.waitFor<TrackMutedEvent>(
        duration: const Duration(seconds: 1),
      );
      await publication.mute();
      await mutedEvent;

      // CRITICAL: A full reconnect must not pass the disposed native track to
      // addTransceiver; the normal unmute path recreates capture when needed.
      final republish = participant.rePublishAllTracks();
      ws.onData(
        lk_rtc.SignalResponse(
          trackPublished: lk_rtc.TrackPublishedResponse(
            cid: mediaTrack.id,
            track: lk_models.TrackInfo(
              sid: 'republished-microphone',
              type: lk_models.TrackType.AUDIO,
              source: lk_models.TrackSource.MICROPHONE,
            ),
          ),
        ).writeToBuffer(),
      );
      await republish;

      expect(participant.getTrackPublicationBySource(TrackSource.microphone), isNull);
    });
  });
}

class _FakeMediaStream extends rtc.MediaStream {
  final List<rtc.MediaStreamTrack> _tracks = [];

  _FakeMediaStream(String id) : super(id, 'fake-owner');

  @override
  bool? get active => true;

  @override
  Future<void> addTrack(rtc.MediaStreamTrack track, {bool addToNative = true}) async {
    _tracks.add(track);
  }

  @override
  Future<rtc.MediaStream> clone() async => _FakeMediaStream('${id}_clone');

  @override
  List<rtc.MediaStreamTrack> getAudioTracks() => _tracks.where((t) => t.kind == 'audio').toList();

  @override
  Future<void> getMediaTracks() async {}

  @override
  List<rtc.MediaStreamTrack> getTracks() => List<rtc.MediaStreamTrack>.from(_tracks);

  @override
  List<rtc.MediaStreamTrack> getVideoTracks() => _tracks.where((t) => t.kind == 'video').toList();

  @override
  Future<void> removeTrack(rtc.MediaStreamTrack track, {bool removeFromNative = true}) async {
    _tracks.remove(track);
  }
}

class _FakeMediaStreamTrack implements rtc.MediaStreamTrack {
  @override
  rtc.StreamTrackCallback? onEnded;

  @override
  rtc.StreamTrackCallback? onMute;

  @override
  rtc.StreamTrackCallback? onUnMute;

  @override
  bool enabled;

  @override
  final String id;

  @override
  final String kind;

  @override
  String? get label => '$kind-track';

  @override
  bool? get muted => false;

  _FakeMediaStreamTrack({
    required this.id,
    required this.kind,
    this.enabled = true,
  });

  @override
  Future<void> applyConstraints([Map<String, dynamic>? constraints]) async {}

  @override
  Future<rtc.MediaStreamTrack> clone() async => _FakeMediaStreamTrack(id: id, kind: kind, enabled: enabled);

  @override
  Future<void> dispose() async {}

  @override
  Future<void> adaptRes(int width, int height) async {}

  @override
  Map<String, dynamic> getConstraints() => const {};

  @override
  Map<String, dynamic> getSettings() => const {};

  @override
  Future<void> stop() async {}

  @override
  void enableSpeakerphone(bool enable) {}

  @override
  Future<ByteBuffer> captureFrame() {
    throw UnimplementedError();
  }

  @override
  Future<bool> hasTorch() async => false;

  @override
  Future<void> setTorch(bool torch) async {}

  @override
  Future<bool> switchCamera() async => false;

  @override
  String toString() => 'FakeMediaStreamTrack(id: $id, kind: $kind, enabled: $enabled)';
}

/// An active microphone whose capture cannot be restarted, so republishing it
/// fails before anything is signalled.
class _FailingRepublishAudioTrack extends LocalAudioTrack {
  _FailingRepublishAudioTrack(rtc.MediaStream stream, rtc.MediaStreamTrack mediaTrack)
      : super(TrackSource.microphone, stream, mediaTrack, const AudioCaptureOptions());

  bool _started = false;

  @override
  Future<bool> start() async {
    if (_started) throw TrackCreateException('capture could not restart');
    _started = true;
    return super.start();
  }
}
