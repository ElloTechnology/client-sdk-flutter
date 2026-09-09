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

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamTrackWeb, MediaStreamWeb;
import 'package:web/web.dart' as web;

import '../../track/local/local.dart' show AudioTrack;
import '_audio_context.dart';

// ignore: implementation_imports

class AudioAnalyser {
  final double Function() calculateVolume;
  final web.AnalyserNode analyser;
  final Future<void> Function() cleanup;

  /// The shared context's current state, read live.
  ///
  /// A suspended context reports `-Infinity` in every frequency bin for as long
  /// as it stays suspended, which is indistinguishable from an analyser wired to
  /// a genuinely silent track. Callers that report "no audio" need this to tell
  /// the two apart.
  final String Function() contextState;

  /// Held only so the source node cannot be collected while the graph is live.
  final web.MediaStreamAudioSourceNode source;

  AudioAnalyser({
    required this.calculateVolume,
    required this.analyser,
    required this.cleanup,
    required this.contextState,
    required this.source,
  });
}

class AudioAnalyserOptions {
  final bool? cloneTrack;
  final num? fftSize;
  final num? smoothingTimeConstant;
  final num? minDecibels;
  final num? maxDecibels;
  const AudioAnalyserOptions({
    this.cloneTrack = false,
    this.fftSize = 2048,
    this.smoothingTimeConstant = 0.8,
    this.minDecibels = -100,
    this.maxDecibels = -80,
  });

  factory AudioAnalyserOptions.from(AudioAnalyserOptions? options) {
    return AudioAnalyserOptions(
      cloneTrack: options?.cloneTrack,
      fftSize: options?.fftSize,
      smoothingTimeConstant: options?.smoothingTimeConstant,
      minDecibels: options?.minDecibels,
      maxDecibels: options?.maxDecibels,
    );
  }
}

/// Document events that count as the user activation an `AudioContext` needs.
const _activationEvents = ['pointerdown', 'touchend', 'keydown'];

web.AudioContext? _sharedContext;
bool _activationListenersAttached = false;

/// The single `AudioContext` every analyser on this page shares.
///
/// A context constructed while the document holds no user activation starts
/// suspended, and a suspended context never advances its analysers. Building one
/// per visualizer therefore lets two analysers on the same page disagree about
/// whether audio is flowing, purely because they were constructed a moment apart
/// — one runs, the other reports silence for the rest of the session. Sharing a
/// single context makes that state one fact instead of several, and gives
/// [_resumeOnActivation] one thing to revive.
web.AudioContext _sharedAudioContext() {
  final existing = _sharedContext;
  if (existing != null) {
    return existing;
  }

  if (!web.window.hasProperty('AudioContext'.toJS).isDefinedAndNotNull) {
    throw Exception('Audio Context not supported on this browser');
  }

  final created = web.AudioContext(web.AudioContextOptions(latencyHint: 'interactive'.toJS));
  _sharedContext = created;

  return created;
}

/// Asks a suspended context to start, without waiting for the answer.
///
/// Deliberately un-awaited: WebKit leaves this promise pending for as long as
/// the document has no user activation rather than rejecting, so awaiting it
/// would stall visualizer setup indefinitely instead of failing. A rejection is
/// equally uninteresting — the context stays suspended either way, and
/// [_resumeOnActivation] is what recovers it.
void _resumeIfSuspended(web.AudioContext context) {
  if (context.state == AudioContextState.running.value) {
    return;
  }

  unawaited(context.resume().toDart.then((_) {}, onError: (_) {}));
}

/// Retries the resume on the user's next interaction with the page.
///
/// A context that starts suspended can only be started by user activation, so
/// without this a page that first builds a visualizer outside the activation
/// window keeps a dead analyser for the rest of its life. The listeners sit on
/// the document because the activation belongs to the page, not to any element
/// the SDK owns; they remove themselves on the first interaction that finds the
/// context already running.
void _resumeOnActivation(web.AudioContext context) {
  if (_activationListenersAttached) {
    return;
  }
  _activationListenersAttached = true;

  late final web.EventListener listener;
  listener = ((web.Event _) {
    if (context.state == AudioContextState.running.value) {
      for (final type in _activationEvents) {
        web.document.removeEventListener(type, listener);
      }
      _activationListenersAttached = false;

      return;
    }

    _resumeIfSuspended(context);
  }).toJS;

  for (final type in _activationEvents) {
    web.document.addEventListener(type, listener);
  }
}

AudioAnalyser? createAudioAnalyser(
  AudioTrack track,
  AudioAnalyserOptions? options,
) {
  final opts = options ?? AudioAnalyserOptions();

  final audioContext = _sharedAudioContext();
  _resumeIfSuspended(audioContext);
  _resumeOnActivation(audioContext);

  final streamTrack = opts.cloneTrack == true ? track.mediaStreamTrack.clone() : track.mediaStreamTrack;
  final mediaStreamSource = audioContext.createMediaStreamSource(
      MediaStreamWeb(web.MediaStream([(streamTrack as MediaStreamTrackWeb).jsTrack].toJS), '').jsStream);
  final analyser = audioContext.createAnalyser();
  analyser.minDecibels = opts.minDecibels ?? -100;
  analyser.maxDecibels = opts.maxDecibels ?? -80;
  analyser.fftSize = opts.fftSize?.toInt() ?? 2048;
  analyser.smoothingTimeConstant = opts.smoothingTimeConstant ?? 0.8;

  mediaStreamSource.connect(analyser);

  /// Calculates the current volume of the track in the range from 0 to 1
  double calculateVolume() {
    final JSUint8Array dataArray = JSUint8Array.withLength(analyser.frequencyBinCount);

    analyser.getByteFrequencyData(dataArray);
    num sum = 0;
    for (var amplitude in dataArray.toDart) {
      sum += math.pow(amplitude / 255, 2);
    }
    final volume = math.sqrt(sum / dataArray.toDart.length);
    return volume;
  }

  Future<void> cleanup() async {
    // Only this analyser's own graph comes down. The context is shared with
    // every other analyser on the page, so closing it here would silence them.
    mediaStreamSource.disconnect();
    analyser.disconnect();
    if (opts.cloneTrack == true) {
      await streamTrack.stop();
    }
  }

  return AudioAnalyser(
    calculateVolume: calculateVolume,
    analyser: analyser,
    cleanup: cleanup,
    contextState: () => audioContext.state,
    source: mediaStreamSource,
  );
}
