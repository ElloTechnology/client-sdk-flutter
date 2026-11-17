/*
 * Copyright 2024 LiveKit, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.livekit.plugin

/**
 * Container for managing audio processors (renderers and visualizers) for a specific audio track
 * Similar to iOS AudioProcessors implementation
 */
class AudioProcessors(
  val track: LKAudioTrack
) {
  val renderers = mutableMapOf<String, AudioRenderer>()
  val visualizers = mutableMapOf<String, LKVisualizer>()

  /**
   * Releases every processor, continuing past one that throws so the rest are
   * still detached from the track. Returns the failures in release order.
   */
  fun cleanup(): List<Exception> {
    val releases = renderers.values.map { renderer -> { renderer.detach() } } +
      visualizers.values.map { visualizer -> { visualizer.stop() } }
    renderers.clear()
    visualizers.clear()

    return releases.mapNotNull { release ->
      try {
        release()
        null
      } catch (e: Exception) {
        e
      }
    }
  }
}
