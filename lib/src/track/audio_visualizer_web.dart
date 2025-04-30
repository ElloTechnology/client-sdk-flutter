import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:livekit_client/src/events.dart' show AudioVisualizerEvent;
import '../logger.dart' show logger;
import 'audio_visualizer.dart';
import 'local/local.dart' show AudioTrack;
import 'web/_audio_analyser.dart';

class AudioVisualizerWeb extends AudioVisualizer {
  AudioAnalyser? _audioAnalyser;
  Timer? _timer;
  final AudioTrack? _audioTrack;
  MediaStreamTrack get mediaStreamTrack => _audioTrack!.mediaStreamTrack;

  final AudioVisualizerOptions visualizerOptions;

  AudioVisualizerWeb(this._audioTrack, {required this.visualizerOptions}) {
    onDispose(() async {
      await events.dispose();
    });
  }

  @override
  Future<void> start() async {
    if (_audioAnalyser != null) {
      return;
    }

    final bands = visualizerOptions.barCount;

    _audioAnalyser = createAudioAnalyser(
        _audioTrack!,
        AudioAnalyserOptions(
          smoothingTimeConstant: visualizerOptions.smoothingTimeConstant,
        ));

    final bufferLength = _audioAnalyser?.analyser.frequencyBinCount;

    _timer = Timer.periodic(
      Duration(milliseconds: visualizerOptions.updateInterval),
      (timer) {
        try {
          var tmp = JSFloat32Array.withLength(bufferLength ?? 0);
          _audioAnalyser?.analyser.getFloatFrequencyData(tmp);
          Float32List frequencies = Float32List(tmp.toDart.length);
          for (var i = 0; i < tmp.toDart.length; i++) {
            var element = tmp.toDart[i];
            frequencies[i] = element;
          }

          final normalizedFrequencies = normalizeFrequencies(frequencies);
          final chunkSize = (normalizedFrequencies.length / (bands + 1)).ceil();
          Float32List chunks = Float32List(visualizerOptions.barCount);

          for (var i = 0; i < bands; i++) {
            final summedVolumes = normalizedFrequencies
                .sublist(i * chunkSize, (i + 1) * chunkSize)
                .reduce((acc, val) => (acc += val));
            chunks[i] = (summedVolumes / chunkSize);
          }

          if (visualizerOptions.centeredBands) {
            chunks = centerBands(chunks);
          }

          events.emit(AudioVisualizerEvent(
            track: _audioTrack,
            event: chunks,
          ));
        } catch (e) {
          logger.warning('Error in visualizer: $e');
        }
      },
    );
  }

  Float32List centerBands(Float32List sortedBands) {
    final centeredBands = Float32List(sortedBands.length);
    var leftIndex = sortedBands.length / 2;
    var rightIndex = leftIndex;

    for (var index = 0; index < sortedBands.length; index++) {
      final value = sortedBands[index];
      if (index % 2 == 0) {
        // Place value to the right
        centeredBands[rightIndex.toInt()] = value;
        rightIndex += 1;
      } else {
        // Place value to the left
        leftIndex -= 1;
        centeredBands[leftIndex.toInt()] = value;
      }
    }

    return centeredBands;
  }

  @override
  Future<void> stop() async {
    if (_audioAnalyser == null) {
      return;
    }

    events.emit(AudioVisualizerEvent(
      track: _audioTrack!,
      event: [],
    ));

    _timer?.cancel();
    _timer = null;

    await _audioAnalyser?.cleanup();
    _audioAnalyser = null;
  }
}

double normalizeDb(num value) {
  const minDb = -100.0;
  const maxDb = -10.0;

  var db =
      1.0 - (math.max(minDb, math.min(maxDb, value)) * -1.0).toDouble() / 100.0;
  db = math.sqrt(db);

  return db;
}

List<num> normalizeFrequencies(List<double> frequencies) {
  // Normalize all frequency values
  return frequencies.map((value) {
    if (value.isInfinite || value.isNaN) {
      return 0;
    }
    return normalizeDb(value);
  }).toList();
}

AudioVisualizer createVisualizerImpl(AudioTrack track,
        {AudioVisualizerOptions? options}) =>
    AudioVisualizerWeb(track,
        visualizerOptions: options ?? AudioVisualizerOptions());
