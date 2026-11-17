package io.livekit.plugin

import org.mockito.Mockito.doThrow
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.webrtc.AudioTrackSink
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * XP-4907: after a full rejoin where the agent keeps its publication, the
 * track id (the SID) maps to a new native track while the cache still wrapped
 * the disposed one, so the next visualizer threw "MediaStreamTrack has been
 * disposed." and lip sync died. Separately, the stop handlers removed entries
 * while iterating the map, threw ConcurrentModificationException, and left
 * later visualizers running.
 */
class AudioProcessorRegistryTest {

  /** Stands in for the native track object flutter_webrtc maps an id to. */
  private class NativeTrack

  private class FakeAudioTrack(private val backing: Any) : LKAudioTrack {
    override fun addSink(sink: AudioTrackSink?) {}
    override fun removeSink(sink: AudioTrackSink) {}
    override fun id(): String = "track"
    override fun isBackedBy(track: Any): Boolean = backing === track
  }

  private val liveTracks = mutableMapOf<String, Any>()
  private val evicted = mutableListOf<Pair<String, Throwable?>>()

  private val registry = AudioProcessorRegistry(
    resolveTrack = { liveTracks[it] },
    wrapTrack = { FakeAudioTrack(it) },
    onStaleEntryEvicted = { trackId, error -> evicted += trackId to error },
  )

  @Test
  fun `reuses the entry while the id still maps to the same track`() {
    liveTracks["TR_agent"] = NativeTrack()

    val first = registry.getOrCreate("TR_agent")
    val second = registry.getOrCreate("TR_agent")

    assertSame(first, second)
    assertTrue(evicted.isEmpty())
  }

  @Test
  fun `replaces an entry whose track was swapped by a rejoin under the same id`() {
    liveTracks["TR_agent"] = NativeTrack()
    val beforeRejoin = registry.getOrCreate("TR_agent")!!
    val staleVisualizer = mock(LKVisualizer::class.java)
    beforeRejoin.visualizers["old"] = staleVisualizer

    val rejoinedTrack = NativeTrack()
    liveTracks["TR_agent"] = rejoinedTrack
    val afterRejoin = registry.getOrCreate("TR_agent")!!

    assertNotSame(beforeRejoin, afterRejoin)
    assertTrue(afterRejoin.track.isBackedBy(rejoinedTrack))
    assertTrue(afterRejoin.visualizers.isEmpty())
    verify(staleVisualizer).stop()
    assertEquals(listOf<Pair<String, Throwable?>>("TR_agent" to null), evicted)
  }

  @Test
  fun `drops the entry and returns null when the track is gone`() {
    liveTracks["TR_agent"] = NativeTrack()
    registry.getOrCreate("TR_agent")
    liveTracks.remove("TR_agent")

    assertNull(registry.getOrCreate("TR_agent"))
    assertEquals(0, registry.size)
    assertEquals(listOf("TR_agent"), evicted.map { it.first })
  }

  @Test
  fun `a failing cleanup of a stale entry is reported and does not block the new entry`() {
    liveTracks["TR_agent"] = NativeTrack()
    val stale = registry.getOrCreate("TR_agent")!!
    val failing = mock(LKVisualizer::class.java)
    val failure = IllegalStateException("MediaStreamTrack has been disposed.")
    doThrow(failure).`when`(failing).stop()
    stale.visualizers["old"] = failing

    liveTracks["TR_agent"] = NativeTrack()

    val fresh = registry.getOrCreate("TR_agent")
    assertNotSame(stale, fresh)
    assertSame(failure, evicted.single().second)
  }

  @Test
  fun `stopping a visualizer stops every holder and drops each emptied entry`() {
    val tracks = listOf("TR_a", "TR_b", "TR_c")
    val visualizers = tracks.associateWith { trackId ->
      liveTracks[trackId] = NativeTrack()
      mock(LKVisualizer::class.java).also {
        registry.getOrCreate(trackId)!!.visualizers["shared"] = it
      }
    }

    registry.stopVisualizer("shared")

    visualizers.values.forEach { verify(it).stop() }
    assertEquals(0, registry.size)
  }

  @Test
  fun `stopping one visualizer leaves other entries in place`() {
    liveTracks["TR_a"] = NativeTrack()
    liveTracks["TR_b"] = NativeTrack()
    val target = mock(LKVisualizer::class.java)
    val other = mock(LKVisualizer::class.java)
    registry.getOrCreate("TR_a")!!.visualizers["target"] = target
    registry.getOrCreate("TR_b")!!.visualizers["other"] = other

    registry.stopVisualizer("target")

    verify(target).stop()
    verify(other, never()).stop()
    assertEquals(1, registry.size)
  }

  @Test
  fun `stopping a renderer detaches every holder and drops each emptied entry`() {
    val renderers = listOf("TR_a", "TR_b", "TR_c").map { trackId ->
      liveTracks[trackId] = NativeTrack()
      mock(AudioRenderer::class.java).also {
        registry.getOrCreate(trackId)!!.renderers["shared"] = it
      }
    }

    registry.stopRenderer("shared")

    renderers.forEach { verify(it).detach() }
    assertEquals(0, registry.size)
  }
}
