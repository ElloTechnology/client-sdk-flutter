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

@Timeout(Duration(seconds: 10))
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:livekit_client/livekit_client.dart';
import '../mock/e2e_container.dart';
import '../mock/peerconnection_mock.dart';

void main() {
  // XP-2139: When an RPC ack never arrives, performRpc's ackTimer must clean up
  // _pendingAcks. Before the fix it only removed the _pendingResponses entry, so
  // the first un-acked RPC leaked a _pendingAcks entry that never cleared —
  // latching pendingRpcAckCount >= 1 (and the derived transport health=unhealthy)
  // for the whole session.
  group('rpc pending-acks leak (XP-2139)', () {
    test('ack-timeout path clears _pendingAcks', () async {
      final container = E2EContainer();
      final room = container.room;
      await container.connectRoom();

      expect(room.localParticipant!.pendingRpcAckCount, 0);

      // Simulate a lost ack: drop every outbound reliable packet so the request
      // is never delivered and neither an ack nor a response ever loops back,
      // forcing the ackTimer to fire.
      findMockDataChannelByLabel('_reliable')!.onMessageSend = (_) {};

      RpcError? error;
      try {
        await room.localParticipant!.performRpc(PerformRpcParams(
          destinationIdentity: room.localParticipant!.identity,
          method: 'echo',
          payload: 'hello',
          responseTimeoutMs: const Duration(seconds: 8),
          ackTimeout: const Duration(milliseconds: 300),
        ));
      } catch (e) {
        if (e is RpcError) error = e;
      }

      expect(error?.code, RpcError.connectionTimeout);

      // CRITICAL: the timed-out RPC must not leave a _pendingAcks entry behind.
      // A non-zero count here is the latched-health leak this test guards.
      expect(room.localParticipant!.pendingRpcAckCount, 0);
    });
  });
}
