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

import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import org.webrtc.AudioTrackSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * AudioRenderer for capturing audio data from WebRTC tracks and streaming to Flutter
 * Similar to iOS AudioRenderer implementation
 */
class AudioRenderer(
  private val audioTrack: LKAudioTrack,
  private val binaryMessenger: BinaryMessenger,
  private val rendererId: String,
  private val targetFormat: RendererAudioFormat
) : EventChannel.StreamHandler, AudioTrackSink {

  companion object {
    private const val TAG = "LK-Profile"

    // Per-category queue instrumentation counters
    @JvmStatic val pendingCount = AtomicInteger(0)
    @JvmStatic val dispatchedCount = AtomicLong(0)
    @JvmStatic val totalDispatchNanos = AtomicLong(0)

    /** Returns a snapshot of [pending, dispatched, totalDispatchNanos]. */
    @JvmStatic fun snapshot(): LongArray = longArrayOf(
      pendingCount.get().toLong(),
      dispatchedCount.get(),
      totalDispatchNanos.get()
    )
  }

  private var eventChannel: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null
  private var isAttached = false

  private val handler: Handler by lazy {
    Handler(Looper.getMainLooper())
  }

  init {
    Trace.beginSection("LK::AudioRenderer::init")
    try {
      Log.d(TAG, "AudioRenderer::init thread=${Thread.currentThread().name} rendererId=$rendererId trackId=${audioTrack.id()}")
      val channelName = "io.livekit.audio.renderer/channel-$rendererId"
      eventChannel = EventChannel(binaryMessenger, channelName)
      eventChannel?.setStreamHandler(this)

      // Attach to the audio track
      audioTrack.addSink(this)
      isAttached = true
    } finally {
      Trace.endSection()
    }
  }

  fun detach() {
    Trace.beginSection("LK::AudioRenderer::detach")
    try {
      Log.d(TAG, "AudioRenderer::detach thread=${Thread.currentThread().name} rendererId=$rendererId")
      if (isAttached) {
        audioTrack.removeSink(this)
        isAttached = false
      }
      eventChannel?.setStreamHandler(null)
      eventSink = null
    } finally {
      Trace.endSection()
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  override fun onData(
    audioData: ByteBuffer,
    bitsPerSample: Int,
    sampleRate: Int,
    numberOfChannels: Int,
    numberOfFrames: Int,
    absoluteCaptureTimestampMs: Long
  ) {
    Trace.beginSection("LK::AudioRenderer::onData")
    try {
      eventSink?.let { sink ->
        try {
          // Convert audio data to the target format
          val convertedData = convertAudioData(
            audioData,
            bitsPerSample,
            sampleRate,
            numberOfChannels,
            numberOfFrames
          )

          // Send to Flutter on the main thread
          pendingCount.incrementAndGet()
          handler.post {
            pendingCount.decrementAndGet()
            val t0 = System.nanoTime()
            Trace.beginSection("LK::AudioRenderer::onData::mainThread")
            try {
              sink.success(convertedData)
            } finally {
              Trace.endSection()
              val elapsed = System.nanoTime() - t0
              dispatchedCount.incrementAndGet()
              totalDispatchNanos.addAndGet(elapsed)
            }
          }
        } catch (e: Exception) {
          pendingCount.incrementAndGet()
          handler.post {
            pendingCount.decrementAndGet()
            val t0 = System.nanoTime()
            sink.error(
              "AUDIO_CONVERSION_ERROR",
              "Failed to convert audio data: ${e.message}",
              null
            )
            val elapsed = System.nanoTime() - t0
            dispatchedCount.incrementAndGet()
            totalDispatchNanos.addAndGet(elapsed)
          }
        }
      }
    } finally {
      Trace.endSection()
    }
  }

  private fun convertAudioData(
    audioData: ByteBuffer,
    bitsPerSample: Int,
    sampleRate: Int,
    numberOfChannels: Int,
    numberOfFrames: Int
  ): Map<String, Any> {
    // Create result similar to iOS implementation
    val result = mutableMapOf<String, Any>(
      "sampleRate" to sampleRate,
      "channels" to numberOfChannels,
      "frameLength" to numberOfFrames
    )

    // Convert based on target format
    when (targetFormat.commonFormat) {
      "int16" -> {
        result["commonFormat"] = "int16"
        result["data"] =
          convertToInt16(audioData, bitsPerSample, numberOfChannels, numberOfFrames)
      }

      "float32" -> {
        result["commonFormat"] = "float32"
        result["data"] =
          convertToFloat32(audioData, bitsPerSample, numberOfChannels, numberOfFrames)
      }

      else -> {
        result["commonFormat"] = "int16" // Default fallback
        result["data"] =
          convertToInt16(audioData, bitsPerSample, numberOfChannels, numberOfFrames)
      }
    }

    return result
  }

  private fun convertToInt16(
    audioData: ByteBuffer,
    bitsPerSample: Int,
    numberOfChannels: Int,
    numberOfFrames: Int
  ): List<List<Int>> {
    val channelsData = mutableListOf<List<Int>>()

    // Prepare buffer for reading
    val buffer = audioData.duplicate()
    buffer.order(ByteOrder.LITTLE_ENDIAN)
    buffer.rewind()

    when (bitsPerSample) {
      16 -> {
        // Already 16-bit, just reformat by channels
        for (channel in 0 until numberOfChannels) {
          val channelData = mutableListOf<Int>()
          buffer.position(0) // Start from beginning for each channel

          for (frame in 0 until numberOfFrames) {
            val sampleIndex = frame * numberOfChannels + channel
            val byteIndex = sampleIndex * 2

            if (byteIndex + 1 < buffer.capacity()) {
              buffer.position(byteIndex)
              val sample = buffer.short.toInt()
              channelData.add(sample)
            }
          }
          channelsData.add(channelData)
        }
      }

      32 -> {
        // Convert from 32-bit to 16-bit
        for (channel in 0 until numberOfChannels) {
          val channelData = mutableListOf<Int>()
          buffer.position(0)

          for (frame in 0 until numberOfFrames) {
            val sampleIndex = frame * numberOfChannels + channel
            val byteIndex = sampleIndex * 4

            if (byteIndex + 3 < buffer.capacity()) {
              buffer.position(byteIndex)
              val sample32 = buffer.int
              // Convert 32-bit to 16-bit by right-shifting
              val sample16 = (sample32 shr 16).toShort().toInt()
              channelData.add(sample16)
            }
          }
          channelsData.add(channelData)
        }
      }

      else -> {
        // Unsupported format, return empty data
        repeat(numberOfChannels) {
          channelsData.add(emptyList())
        }
      }
    }

    return channelsData
  }

  private fun convertToFloat32(
    audioData: ByteBuffer,
    bitsPerSample: Int,
    numberOfChannels: Int,
    numberOfFrames: Int
  ): List<List<Float>> {
    val channelsData = mutableListOf<List<Float>>()

    val buffer = audioData.duplicate()
    buffer.order(ByteOrder.LITTLE_ENDIAN)
    buffer.rewind()

    when (bitsPerSample) {
      16 -> {
        // Convert from 16-bit to float32
        for (channel in 0 until numberOfChannels) {
          val channelData = mutableListOf<Float>()
          buffer.position(0)

          for (frame in 0 until numberOfFrames) {
            val sampleIndex = frame * numberOfChannels + channel
            val byteIndex = sampleIndex * 2

            if (byteIndex + 1 < buffer.capacity()) {
              buffer.position(byteIndex)
              val sample16 = buffer.short
              // Convert to float (-1.0 to 1.0)
              val sampleFloat = sample16.toFloat() / Short.MAX_VALUE
              channelData.add(sampleFloat)
            }
          }
          channelsData.add(channelData)
        }
      }

      32 -> {
        // Assume 32-bit float input
        for (channel in 0 until numberOfChannels) {
          val channelData = mutableListOf<Float>()
          buffer.position(0)

          for (frame in 0 until numberOfFrames) {
            val sampleIndex = frame * numberOfChannels + channel
            val byteIndex = sampleIndex * 4

            if (byteIndex + 3 < buffer.capacity()) {
              buffer.position(byteIndex)
              val sampleFloat = buffer.float
              channelData.add(sampleFloat)
            }
          }
          channelsData.add(channelData)
        }
      }

      else -> {
        // Unsupported format
        repeat(numberOfChannels) {
          channelsData.add(emptyList())
        }
      }
    }

    return channelsData
  }
}

/**
 * Audio format specification for the renderer
 */
data class RendererAudioFormat(
  val bitsPerSample: Int,
  val sampleRate: Int,
  val numberOfChannels: Int,
  val commonFormat: String = "int16"
) {
  companion object {
    fun fromMap(formatMap: Map<String, Any?>): RendererAudioFormat? {
      val bitsPerSample = formatMap["bitsPerSample"] as? Int ?: 16
      val sampleRate = formatMap["sampleRate"] as? Int ?: 48000
      val numberOfChannels = formatMap["channels"] as? Int ?: 1
      val commonFormat = formatMap["commonFormat"] as? String ?: "int16"

      return RendererAudioFormat(bitsPerSample, sampleRate, numberOfChannels, commonFormat)
    }
  }
}
