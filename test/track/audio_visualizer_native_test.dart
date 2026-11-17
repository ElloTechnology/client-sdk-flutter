// Copyright 2026 LiveKit, Inc.
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

@TestOn('vm')
library;

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/support/native.dart';
import 'package:livekit_client/src/track/audio_visualizer_native.dart';

class _FakeMediaStream extends Fake implements rtc.MediaStream {}

class _FakeMediaStreamTrack extends Fake implements rtc.MediaStreamTrack {
  @override
  final String id = 'TR_agent';

  @override
  final String kind = 'audio';

  @override
  rtc.StreamTrackCallback? onEnded;
}

/// XP-4907: the Android plugin replied `null` on a successful start, so
/// `Native.startVisualizer` returned false on success and failure alike and the
/// visualizer ignored it. A start that failed natively looked like a visualizer
/// on a silent track.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  void replyToStart(Object? Function() reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(Native.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'startVisualizer') return reply();
      return null;
    });
  }

  AudioVisualizerNative visualizer() => AudioVisualizerNative(
        LocalAudioTrack(
          TrackSource.microphone,
          _FakeMediaStream(),
          _FakeMediaStreamTrack(),
          const AudioCaptureOptions(),
        ),
        visualizerOptions: const AudioVisualizerOptions(),
      );

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(Native.channel, null);
  });

  test('start completes when the platform reports the visualizer started', () async {
    replyToStart(() => true);

    await visualizer().start();

    expect(calls.single.method, 'startVisualizer');
    expect((calls.single.arguments as Map)['trackId'], 'TR_agent');
  });

  test('start throws when the platform rejects the visualizer', () async {
    replyToStart(() => throw PlatformException(code: 'INVALID_ARGUMENT', message: 'track not found'));

    await expectLater(visualizer().start(), throwsA(isA<AudioVisualizerException>()));
  });

  test('start throws when the platform does not confirm the start', () async {
    replyToStart(() => null);

    await expectLater(visualizer().start(), throwsA(isA<AudioVisualizerException>()));
  });
}
