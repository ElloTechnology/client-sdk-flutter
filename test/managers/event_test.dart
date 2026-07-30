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

// XP-3071 / Sentry LEARN-FRONTEND-2EA,2EB,2EK,2F0: every `TimeoutException:
// LiveKit Exception [TimeoutException] Timeout` an SDK event handler raised
// reached the host app's root zone as a crash. `listen` hands an async handler
// to `Stream.listen`, which drops the future it returns, so nothing between the
// throw and the zone could see it.

@Timeout(Duration(seconds: 5))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:livekit_client/src/exceptions.dart' as lk;
import 'package:livekit_client/src/managers/event.dart';

class _TestEvent {
  final String name;

  const _TestEvent(this.name);
}

class _OtherEvent {}

void main() {
  group('EventsListenable error containment', () {
    late List<LogRecord> logs;
    late StreamSubscription<LogRecord> logSub;

    setUp(() {
      logs = [];
      Logger.root.level = Level.ALL;
      logSub = Logger.root.onRecord.listen(logs.add);
    });

    tearDown(() async {
      await logSub.cancel();
    });

    for (final synchronized in [false, true]) {
      test('a throwing async handler is reported, not escaped (synchronized: $synchronized)', () async {
        final zoneErrors = <Object>[];
        await runZonedGuarded(() async {
          // The subscription must be created inside the guarded zone: that is
          // the zone an escaping handler error is delivered to, and in the host
          // app it is the root zone.
          final emitter = EventsEmitter<Object>(listenSynchronized: synchronized);
          addTearDown(emitter.dispose);

          emitter.on<_TestEvent>((event) async {
            await Future<void>.delayed(Duration.zero);
            throw lk.TimeoutException();
          });

          emitter.emit(const _TestEvent('first'));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }, (error, _) => zoneErrors.add(error));

        expect(zoneErrors, isEmpty, reason: 'handler errors must not reach the root zone');
        expect(
          logs.where((r) => r.level == Level.SEVERE && r.error is lk.TimeoutException),
          hasLength(1),
        );
      });

      test('a later event still reaches the same listener (synchronized: $synchronized)', () async {
        final seen = <String>[];
        final zoneErrors = <Object>[];
        await runZonedGuarded(() async {
          final emitter = EventsEmitter<Object>(listenSynchronized: synchronized);
          addTearDown(emitter.dispose);

          emitter.on<_TestEvent>((event) async {
            seen.add(event.name);
            if (event.name == 'first') throw lk.TimeoutException();
          });

          emitter.emit(const _TestEvent('first'));
          await Future<void>.delayed(const Duration(milliseconds: 10));
          emitter.emit(const _TestEvent('second'));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }, (error, _) => zoneErrors.add(error));

        // A contained failure must not cost the subscription: the emitter is
        // the only delivery path for every later event of this type.
        expect(seen, ['first', 'second']);
        expect(zoneErrors, isEmpty);
      });
    }

    test('a synchronized listener keeps ordering after a handler throws', () async {
      // The signal listener is synchronized, so a handler that throws while
      // holding the lock must still release it — otherwise one failed handler
      // stalls every later signal event.
      final completed = <String>[];
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final emitter = EventsEmitter<Object>(listenSynchronized: true);
        addTearDown(emitter.dispose);

        emitter.on<_TestEvent>((event) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          completed.add(event.name);
          throw lk.TimeoutException(event.name);
        });
        emitter.on<_OtherEvent>((event) async {
          completed.add('other');
        });

        emitter.emit(const _TestEvent('slow'));
        emitter.emit(_OtherEvent());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }, (error, _) => zoneErrors.add(error));

      expect(completed, ['slow', 'other']);
      expect(zoneErrors, isEmpty);
    });
  });
}
