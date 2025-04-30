import 'package:livekit_client/src/support/disposable.dart';
import '../events.dart' show AudioVisualizerEvent;
import '../managers/event.dart' show EventsEmittable;
import 'local/local.dart' show AudioTrack;

import 'audio_visualizer_native.dart'
    if (dart.library.js_interop) 'audio_visualizer_web.dart';

class AudioVisualizerOptions {
  final bool centeredBands;
  final int barCount;

  /// Update interval in milliseconds (default: 50ms).
  final int updateInterval;

  /// Analyser smoothingTimeConstant (0.0 to 1.0, default: 0.8).
  /// Lower values are more responsive.
  final double smoothingTimeConstant;

  const AudioVisualizerOptions({
    this.centeredBands = true,
    this.barCount = 7,
    this.updateInterval = 50, // Default to 50ms
    this.smoothingTimeConstant = 0.8, // Default to 0.8
  });
}

abstract class AudioVisualizer extends DisposableChangeNotifier
    with EventsEmittable<AudioVisualizerEvent> {
  Future<void> start();
  Future<void> stop();
}

AudioVisualizer createVisualizer(AudioTrack track,
        {AudioVisualizerOptions? options}) =>
    createVisualizerImpl(track, options: options);
