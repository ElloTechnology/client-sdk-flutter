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

import android.os.Trace
import android.util.Log
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink

class LKRemoteAudioTrack(audioTrack: AudioTrack) : LKAudioTrack {
    companion object {
        private const val TAG = "LK-Profile"
    }

    private var audioTrack: AudioTrack? = audioTrack

    override fun addSink(sink: AudioTrackSink?) {
        Trace.beginSection("LK::LKRemoteAudioTrack::addSink")
        try {
            Log.d(TAG, "LKRemoteAudioTrack::addSink thread=${Thread.currentThread().name} trackId=${id()}")
            audioTrack?.addSink(sink)
        } finally {
            Trace.endSection()
        }
    }

    override fun removeSink(sink: AudioTrackSink) {
        Trace.beginSection("LK::LKRemoteAudioTrack::removeSink")
        try {
            Log.d(TAG, "LKRemoteAudioTrack::removeSink thread=${Thread.currentThread().name} trackId=${id()}")
            audioTrack?.removeSink(sink)
        } finally {
            Trace.endSection()
        }
    }

    override fun id(): String {
        return audioTrack?.id() ?: ""
    }
}