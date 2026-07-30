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

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:sdp_transform/sdp_transform.dart' as sdp_transform;

import '../exceptions.dart';
import '../extensions.dart';
import '../internal/types.dart';
import '../logger.dart';
import '../options.dart';
import '../support/disposable.dart';
import '../support/platform.dart';
import '../types/other.dart';
import '../utils.dart';

const ddExtensionURI = 'https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension';

/* The svc codec (av1/vp9) would use a very low bitrate at the begining and
increase slowly by the bandwidth estimator until it reach the target bitrate. The
process commonly cost more than 10 seconds cause subscriber will get blur video at
the first few seconds. So we use a 70% of target bitrate here as the start bitrate to
eliminate this issue.
*/
const startBitrateForSVC = 0.7;

class TrackBitrateInfo {
  String? cid;
  rtc.RTCRtpTransceiver? transceiver;
  String codec;
  int maxbr;
  TrackBitrateInfo({
    required this.cid,
    required this.transceiver,
    required this.codec,
    required this.maxbr,
  });
}

typedef TransportOnOffer = void Function(rtc.RTCSessionDescription offer);
typedef TransportOnNegotiationFailed = void Function(Object error, StackTrace stackTrace);
typedef PeerConnectionCreate = Future<rtc.RTCPeerConnection> Function(Map<String, dynamic> configuration,
    [Map<String, dynamic> constraints]);

/// a wrapper around PeerConnection
class Transport extends Disposable {
  final rtc.RTCPeerConnection pc;
  final List<rtc.RTCIceCandidate> _pendingCandidates = [];
  final List<TrackBitrateInfo> _bitrateTrackers = [];
  bool restartingIce = false;
  bool renegotiate = false;
  TransportOnOffer? onOffer;
  TransportOnNegotiationFailed? onNegotiationFailed;
  Function? _cancelDebounce;
  ConnectOptions connectOptions;

  // private constructor
  Transport._(this.pc, this.connectOptions) {
    //
    onDispose(() async {
      _cancelDebounce?.call();
      _cancelDebounce = null;

      // A negotiation already in flight must not report into whatever replaced
      // this transport.
      onOffer = null;
      onNegotiationFailed = null;

      // Ensure callbacks won't fire any more
      pc.onRenegotiationNeeded = null;
      pc.onIceCandidate = null;
      pc.onConnectionState = null;
      pc.onIceConnectionState = null;
      pc.onTrack = null;

      // Remove all senders
      List<rtc.RTCRtpSender> senders = [];
      try {
        senders = await pc.getSenders();
      } catch (err) {
        logger.warning('getSenders() failed with error: $err');
      }

      for (final e in senders) {
        try {
          await pc.removeTrack(e);
        } catch (err) {
          logger.warning('removeTrack() failed with error: $err');
        }
      }

      await pc.close();
      await pc.dispose();
    });
  }

  static Future<Transport> create(PeerConnectionCreate peerConnectionCreate,
      {RTCConfiguration? rtcConfig, required ConnectOptions connectOptions}) async {
    rtcConfig ??= const RTCConfiguration();
    logger.fine('[PCTransport] creating ${rtcConfig.toMap()}');
    final pc = await peerConnectionCreate(rtcConfig.toMap());
    return Transport._(pc, connectOptions);
  }

  late final negotiate = Utils.createDebounceFunc(
    (void _) => _createAndSendOfferReportingFailure(),
    cancelFunc: (f) => _cancelDebounce = f,
    wait: connectOptions.timeouts.debounce,
  );

  /// The debounced [negotiate] fires from a timer, so nothing is left to await its
  /// result — a failure here would otherwise escape as an unhandled async error and
  /// never reach the recovery path that owns renegotiation failures.
  Future<void> _createAndSendOfferReportingFailure() async {
    try {
      await createAndSendOffer();
    } catch (error, stackTrace) {
      // A call already issued to the native layer rejects rather than returning
      // when disposal frees the connection underneath it. That is teardown, not a
      // negotiation failure, and must not drive recovery for a dead transport.
      if (isDisposed) {
        logger.warning('[$objectId] negotiation aborted by disposal: $error');
        return;
      }
      logger.warning('[$objectId] negotiation failed with error: $error', error, stackTrace);
      onNegotiationFailed?.call(error, stackTrace);
    }
  }

  Future<void> setRemoteDescription(rtc.RTCSessionDescription sd) async {
    if (isDisposed) {
      logger.warning('[$objectId] setRemoteDescription() already disposed');
      return;
    }

    try {
      await pc.setRemoteDescription(sd);
    } catch (e) {
      logger.warning('[$objectId] setRemoteDescription() failed with error: $e');
    }

    for (final candidate in _pendingCandidates) {
      await pc.addCandidate(candidate);
    }

    _pendingCandidates.clear();
    restartingIce = false;

    if (renegotiate) {
      renegotiate = false;
      await createAndSendOffer(); // await or un-awaited ?
    }
  }

  /// Disposal closes and frees the native peer connection, and [isDisposed] flips
  /// before that teardown runs. Negotiation spans several round-trips to the native
  /// layer, so every resumption point has to re-check before touching [pc] again —
  /// otherwise the call lands on a connection that no longer exists.
  bool get _disposedMidNegotiation {
    if (!isDisposed) return false;
    logger.warning('[$objectId] createAndSendOffer() disposed mid-negotiation, aborting');
    return true;
  }

  Future<void> createAndSendOffer([RTCOfferOptions? options]) async {
    if (isDisposed) {
      logger.warning('[$objectId] createAndSendOffer() already disposed');
      return;
    }

    if (onOffer == null) {
      logger.warning('onOffer is null');
      return;
    }

    if (options?.iceRestart ?? false) {
      logger.fine('restarting ICE');
      restartingIce = true;
    }

    final signalingState = await pc.getSignalingState();
    if (_disposedMidNegotiation) return;

    if (signalingState == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      // we're waiting for the peer to accept our offer, so we'll just wait
      // the only exception to this is when ICE restart is needed
      final currentSD = await getRemoteDescription();
      if (_disposedMidNegotiation) return;

      if ((options?.iceRestart ?? false) && currentSD != null) {
        // TODO: handle when ICE restart is needed but we don't have a remote description
        // the best thing to do is to recreate the peerconnection
        await pc.setRemoteDescription(currentSD);
        if (_disposedMidNegotiation) return;
      } else {
        renegotiate = true;
        return;
      }
    }

    if (restartingIce && !lkPlatformIs(PlatformType.web)) {
      await pc.restartIce();
      if (_disposedMidNegotiation) return;
    }

    // actually negotiate
    logger.fine('starting to negotiate');
    final offer = await pc.createOffer(options?.toMap() ?? <String, dynamic>{});
    if (_disposedMidNegotiation) return;

    final sdpParsed = sdp_transform.parse(offer.sdp ?? '');
    sdpParsed['media']?.forEach((media) {
      if (media['type'] == 'video') {
        ensureVideoDDExtensionForSVC(media, media['type'], media['port'], media['protocol'], media['payloads']);

        // mung sdp for codec bitrate setting that can't apply by sendEncoding
        for (var trackbr in _bitrateTrackers) {
          if (media['msid'] == null || trackbr.cid == null || !(media['msid'] as String).contains(trackbr.cid!)) {
            continue;
          }

          var codecPayload = 0;
          for (var rtp in media['rtp']) {
            if (rtp['codec']?.toUpperCase() == trackbr.codec.toUpperCase()) {
              codecPayload = rtp['payload'];
              continue;
            }
            continue;
          }

          if (codecPayload == 0) {
            continue;
          }

          for (var fmtp in media['fmtp']) {
            if (fmtp['payload'] == codecPayload) {
              if (!(fmtp['config'] as String).contains('x-google-start-bitrate')) {
                fmtp['config'] += ';x-google-start-bitrate=${(trackbr.maxbr * startBitrateForSVC).toInt()}';
              }
              break;
            }
          }
          continue;
        }
      }
    });

    try {
      await setMungedSDP(sd: offer, munged: sdp_transform.write(sdpParsed, null));
    } catch (e) {
      throw NegotiationError(e.toString());
    }
    // Disposal can abort setMungedSDP before the description is applied, and an
    // offer the local peer never adopted must not be published.
    if (_disposedMidNegotiation) return;
    onOffer?.call(offer);
  }

  Future<void> addIceCandidate(rtc.RTCIceCandidate candidate) async {
    if (isDisposed) {
      logger.warning('[$objectId] addIceCandidate() already disposed');
      return;
    }

    final desc = await getRemoteDescription();

    if (desc != null && !restartingIce) {
      await pc.addCandidate(candidate);
      return;
    }

    _pendingCandidates.add(candidate);
  }

  Future<rtc.RTCSessionDescription?> getRemoteDescription() async {
    if (isDisposed) {
      logger.warning('[$objectId] getRemoteDescription() already disposed');
      return null;
    }

    // Checking agains null doesn't work as intended
    // if (pc.iceConnectionState == null) return null;

    try {
      final result = await pc.getRemoteDescription();
      return result;
    } catch (err) {
      logger.warning('pc.getRemoteDescription failed with error: $err');
    }
    return null;
  }

  void setTrackBitrateInfo(TrackBitrateInfo info) {
    _bitrateTrackers.add(info);
  }

  bool ensureVideoDDExtensionForSVC(
    Map<String, dynamic> media,
    String? type,
    num port,
    String protocol,
    String? payloads,
  ) {
    final codec = media['rtp']?[0]?['codec']?.toLowerCase();
    if (!isSVCCodec(codec)) {
      return false;
    }

    var maxID = 0;
    bool ddFound = false;
    final List<dynamic>? ext = media['ext'];
    if (ext != null) {
      for (var e in ext) {
        if (e['uri'] == ddExtensionURI) {
          ddFound = true;
          continue;
        }
        if (e['value'] > maxID) {
          maxID = e['value'];
        }
      }
    }

    if (!ddFound) {
      ext?.add({
        'value': maxID + 1,
        'uri': ddExtensionURI,
      });
    }

    return ddFound;
  }

  Future<void> setMungedSDP({required rtc.RTCSessionDescription sd, String? munged, bool? remote}) async {
    if (munged != null) {
      final originalSdp = sd.sdp;
      sd.sdp = munged;
      try {
        logger.fine('setting munged ${remote == true ? 'remote' : 'local'}');
        logger.finer('description munged: $munged ');
        if (remote == true) {
          await pc.setRemoteDescription(sd);
        } else {
          await pc.setLocalDescription(sd);
        }
        return;
      } catch (e) {
        logger.warning('not able to set ${sd.type}, falling back to unmodified sdp error: $e, sdp: $munged ');
        sd.sdp = originalSdp;
        // A description only fails to apply because the connection went away once
        // disposal has run; retrying the unmodified sdp would fail the same way.
        if (_disposedMidNegotiation) return;
      }
    }

    try {
      if (remote == true) {
        await pc.setRemoteDescription(sd);
      } else {
        await pc.setLocalDescription(sd);
      }
    } catch (e) {
      // this error cannot always be caught.ght
      logger.warning('unable to set ${sd.type}, error: $e, sdp: ${sd.sdp}');
      rethrow;
    }
  }
}
