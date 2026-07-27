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

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/extensions.dart';
import 'package:livekit_client/src/proto/livekit_models.pbenum.dart' as lk_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;

/// Restated independently of production so that a mistake in the production
/// mapping shows up as a test failure rather than being mirrored by it.
const _expected = <lk_models.DisconnectReason, DisconnectReason>{
  lk_models.DisconnectReason.UNKNOWN_REASON: DisconnectReason.unknown,
  lk_models.DisconnectReason.CLIENT_INITIATED: DisconnectReason.clientInitiated,
  lk_models.DisconnectReason.DUPLICATE_IDENTITY: DisconnectReason.duplicateIdentity,
  lk_models.DisconnectReason.SERVER_SHUTDOWN: DisconnectReason.serverShutdown,
  lk_models.DisconnectReason.PARTICIPANT_REMOVED: DisconnectReason.participantRemoved,
  lk_models.DisconnectReason.ROOM_DELETED: DisconnectReason.roomDeleted,
  lk_models.DisconnectReason.STATE_MISMATCH: DisconnectReason.stateMismatch,
  lk_models.DisconnectReason.JOIN_FAILURE: DisconnectReason.joinFailure,
  lk_models.DisconnectReason.MIGRATION: DisconnectReason.migration,
  lk_models.DisconnectReason.SIGNAL_CLOSE: DisconnectReason.signalClose,
  lk_models.DisconnectReason.ROOM_CLOSED: DisconnectReason.roomClosed,
  lk_models.DisconnectReason.USER_UNAVAILABLE: DisconnectReason.userUnavailable,
  lk_models.DisconnectReason.USER_REJECTED: DisconnectReason.userRejected,
  lk_models.DisconnectReason.SIP_TRUNK_FAILURE: DisconnectReason.sipTrunkFailure,
  lk_models.DisconnectReason.CONNECTION_TIMEOUT: DisconnectReason.connectionTimeout,
  lk_models.DisconnectReason.MEDIA_FAILURE: DisconnectReason.mediaFailure,
  lk_models.DisconnectReason.AGENT_ERROR: DisconnectReason.agentError,
};

/// Larger than any generated protocol reason, standing in for a value sent by a
/// server newer than this SDK's protobuf.
const _futureWireValue = 127;

void main() {
  group('protocol to public DisconnectReason', () {
    test('every generated protocol reason is classified', () {
      expect(
        _expected.keys.toSet(),
        equals(lk_models.DisconnectReason.values.toSet()),
        reason: 'A protocol reason was added or removed by codegen without a deliberate public mapping.',
      );
    });

    test('the production map matches the expected map exactly', () {
      expect(kProtocolToPublicDisconnectReason, equals(_expected));
    });

    test('each protocol reason converts to its own public reason', () {
      for (final protocolReason in lk_models.DisconnectReason.values) {
        expect(
          protocolReason.toSDKType(),
          equals(_expected[protocolReason]),
          reason: 'Wrong public reason for ${protocolReason.name}.',
        );
      }
    });

    test('distinct protocol reasons stay distinct once public', () {
      final publicReasons = lk_models.DisconnectReason.values.map((e) => e.toSDKType()).toList();
      expect(
        publicReasons.toSet().length,
        equals(publicReasons.length),
        reason: 'Two protocol reasons collapsed onto one public reason, losing server attribution.',
      );
    });

    test('the SDK-synthesized reasons keep their historical indices', () {
      // These are persisted and compared by index elsewhere, so appending new
      // values must never shift them.
      expect(DisconnectReason.disconnected.index, 8);
      expect(DisconnectReason.signalingConnectionFailure.index, 9);
      expect(DisconnectReason.reconnectAttemptsExceeded.index, 10);
    });
  });

  group('wire round-trip', () {
    test('AGENT_ERROR survives serialization as value 16', () {
      final bytes = lk_rtc.LeaveRequest(
        reason: lk_models.DisconnectReason.AGENT_ERROR,
        action: lk_rtc.LeaveRequest_Action.DISCONNECT,
      ).writeToBuffer();

      final parsed = lk_rtc.LeaveRequest.fromBuffer(bytes);

      expect(parsed.reason.value, 16);
      expect(parsed.reason, lk_models.DisconnectReason.AGENT_ERROR);
      expect(parsed.reason.toSDKType(), DisconnectReason.agentError);
    });

    test('a reason newer than the generated protocol degrades to unknown', () {
      // Hand-built so the payload is not limited to values this SDK can name:
      // field 2 (reason), varint wire type, carrying a future enum value.
      final bytes = Uint8List.fromList([(2 << 3) | 0, _futureWireValue]);

      final parsed = lk_rtc.LeaveRequest.fromBuffer(bytes);

      // The protobuf runtime keeps the unrecognized value out of the typed
      // field, so the reason arrives as the default rather than as an enum
      // instance the conversion has never seen.
      expect(parsed.reason, lk_models.DisconnectReason.UNKNOWN_REASON);
      expect(parsed.reason.toSDKType(), DisconnectReason.unknown);
    });
  });
}
