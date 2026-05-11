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

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'package:livekit_client/livekit_client.dart';

class _StubMediaStream implements rtc.MediaStream {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubMediaStreamTrack implements rtc.MediaStreamTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTrack extends Track {
  _FakeTrack()
      : super(
          TrackType.AUDIO,
          TrackSource.microphone,
          _StubMediaStream(),
          _StubMediaStreamTrack(),
        );

  @override
  Future<bool> monitorStats() async => false;
}

void main() {
  group('Track.statsMonitorEnabled', () {
    tearDown(() {
      // Restore fork default so subsequent tests are unaffected.
      Track.statsMonitorEnabled = false;
    });

    test('defaults to false in this fork (diverges from upstream)', () {
      expect(Track.statsMonitorEnabled, isFalse);
    });

    test('startMonitor is a no-op at the default', () {
      final track = _FakeTrack();

      track.startMonitor();

      expect(track.hasActiveStatsMonitor, isFalse);
    });

    test('startMonitor schedules the timer when enabled', () {
      Track.statsMonitorEnabled = true;
      final track = _FakeTrack();
      addTearDown(track.stopMonitor);

      track.startMonitor();

      expect(track.hasActiveStatsMonitor, isTrue);
    });

    test('toggling at runtime does not stop already-running monitors', () {
      Track.statsMonitorEnabled = true;
      final track = _FakeTrack();
      addTearDown(track.stopMonitor);

      track.startMonitor();
      expect(track.hasActiveStatsMonitor, isTrue);

      Track.statsMonitorEnabled = false;
      // Existing monitor is unaffected; documented contract is "set once
      // before any Track is constructed".
      expect(track.hasActiveStatsMonitor, isTrue);
    });
  });
}
