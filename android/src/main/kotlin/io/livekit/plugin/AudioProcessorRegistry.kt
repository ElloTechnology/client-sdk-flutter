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
 * The visualizers and renderers attached to each audio track, keyed by the
 * flutter_webrtc track id.
 *
 * A track id does not identify one native track for the life of the process:
 * LiveKit uses the track SID as the WebRTC track id, so a full rejoin where the
 * remote participant keeps its publication maps the same id to a new track on
 * the new peer connection, and the old one is disposed. Every lookup therefore
 * resolves the live track first and replaces an entry that wraps anything else.
 *
 * Calls must come from one thread; the plugin's method channel runs on a serial
 * background task queue.
 */
class AudioProcessorRegistry(
  /** The object flutter_webrtc currently maps [trackId] to, or null when none. */
  private val resolveTrack: (trackId: String) -> Any?,
  /** Wraps a resolved track object, or returns null when it is not audio. */
  private val wrapTrack: (track: Any) -> LKAudioTrack?,
  /** Reports an entry dropped because its track was no longer the live one. */
  private val onStaleEntryEvicted: (trackId: String, cleanupError: Throwable?) -> Unit = { _, _ -> },
) {
  private val entries = mutableMapOf<String, AudioProcessors>()

  /** The number of tracks holding at least one processor. */
  val size: Int get() = entries.size

  /** The processors for the live track behind [trackId], creating them when needed. */
  fun getOrCreate(trackId: String): AudioProcessors? {
    val liveTrack = resolveTrack(trackId)
    val cached = entries[trackId]

    if (cached != null) {
      if (liveTrack != null && cached.track.isBackedBy(liveTrack)) return cached
      entries.remove(trackId)
      onStaleEntryEvicted(trackId, cleanUp(cached))
    }

    val wrapped = liveTrack?.let(wrapTrack) ?: return null
    return AudioProcessors(wrapped).also { entries[trackId] = it }
  }

  /** Stops [visualizerId] on every track and drops entries left with no processors. */
  fun stopVisualizer(visualizerId: String) = removeEach { processors ->
    processors.visualizers.remove(visualizerId)?.stop()
  }

  /** Detaches [rendererId] from every track and drops entries left with no processors. */
  fun stopRenderer(rendererId: String) = removeEach { processors ->
    processors.renderers.remove(rendererId)?.detach()
  }

  /** Releases every processor. */
  fun clear() {
    entries.values.forEach { cleanUp(it) }
    entries.clear()
  }

  private fun removeEach(release: (AudioProcessors) -> Unit) {
    val iterator = entries.values.iterator()
    while (iterator.hasNext()) {
      val processors = iterator.next()
      release(processors)
      if (processors.visualizers.isEmpty() && processors.renderers.isEmpty()) {
        iterator.remove()
      }
    }
  }

  private fun cleanUp(processors: AudioProcessors): Throwable? =
    try {
      processors.cleanup()
      null
    } catch (e: Exception) {
      e
    }
}
