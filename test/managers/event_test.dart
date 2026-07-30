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
// throw and the zone could see it. Containment is opt-in: the SDK sets it on
// the listeners it owns, and an application's own handlers keep reporting their
// bugs to the application's zone.

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

    Iterable<LogRecord> severeTimeouts() =>
        logs.where((r) => r.level == Level.SEVERE && r.error is lk.TimeoutException);

    for (final synchronized in [false, true]) {
      test('a contained listener reports a throwing handler (synchronized: $synchronized)', () async {
        final handled = Completer<void>();
        final zoneErrors = <Object>[];

        await runZonedGuarded(() async {
          // The subscription must be created inside the guarded zone: that is
          // the zone an escaping handler error is delivered to, and in the host
          // application it is the root zone.
          final emitter = EventsEmitter<Object>();
          addTearDown(emitter.dispose);
          final listener = EventsListener<Object>(
            emitter,
            synchronized: synchronized,
            containErrors: true,
          );
          addTearDown(listener.dispose);

          listener.on<_TestEvent>((event) async {
            try {
              throw lk.TimeoutException();
            } finally {
              handled.complete();
            }
          });

          emitter.emit(const _TestEvent('first'));
          await handled.future;
          await pumpEventQueue();
        }, (error, _) => zoneErrors.add(error));

        expect(zoneErrors, isEmpty, reason: 'a contained handler must not reach the root zone');
        expect(severeTimeouts(), hasLength(1));
      });

      test('a contained listener keeps its subscription (synchronized: $synchronized)', () async {
        final seen = <String>[];
        final secondSeen = Completer<void>();
        final zoneErrors = <Object>[];

        await runZonedGuarded(() async {
          final emitter = EventsEmitter<Object>();
          addTearDown(emitter.dispose);
          final listener = EventsListener<Object>(
            emitter,
            synchronized: synchronized,
            containErrors: true,
          );
          addTearDown(listener.dispose);

          listener.on<_TestEvent>((event) async {
            seen.add(event.name);
            if (event.name == 'second') secondSeen.complete();
            if (event.name == 'first') throw lk.TimeoutException();
          });

          emitter.emit(const _TestEvent('first'));
          emitter.emit(const _TestEvent('second'));
          await secondSeen.future;
        }, (error, _) => zoneErrors.add(error));

        // A contained failure must not cost the subscription: the emitter is
        // the only delivery path for every later event of this type.
        expect(seen, ['first', 'second']);
        expect(zoneErrors, isEmpty);
      });
    }

    test('an uncontained listener still reports to its own zone', () async {
      // Containment is opt-in. An application listening on `room.events` owns
      // its handlers, and swallowing their errors would take its own bugs out
      // of its crash reporting and leave them as SDK log lines.
      final handled = Completer<void>();
      final zoneErrors = <Object>[];

      await runZonedGuarded(() async {
        final emitter = EventsEmitter<Object>();
        addTearDown(emitter.dispose);
        final listener = EventsListener<Object>(emitter);
        addTearDown(listener.dispose);

        listener.on<_TestEvent>((event) async {
          try {
            throw lk.TimeoutException();
          } finally {
            handled.complete();
          }
        });

        emitter.emit(const _TestEvent('first'));
        await handled.future;
        await pumpEventQueue();
      }, (error, _) => zoneErrors.add(error));

      expect(zoneErrors, hasLength(1));
      expect(zoneErrors.single, isA<lk.TimeoutException>());
      expect(severeTimeouts(), isEmpty);
    });

    test('a contained synchronized listener keeps ordering after a handler throws', () async {
      // The engine's signal listener is synchronized, so a handler that throws
      // while holding the lock must still release it — otherwise one failed
      // handler stalls every later signal event.
      final completed = <String>[];
      final otherSeen = Completer<void>();
      final zoneErrors = <Object>[];

      await runZonedGuarded(() async {
        final emitter = EventsEmitter<Object>();
        addTearDown(emitter.dispose);
        final listener = EventsListener<Object>(emitter, synchronized: true, containErrors: true);
        addTearDown(listener.dispose);

        listener.on<_TestEvent>((event) async {
          await pumpEventQueue();
          completed.add(event.name);
          throw lk.TimeoutException(event.name);
        });
        listener.on<_OtherEvent>((event) async {
          completed.add('other');
          otherSeen.complete();
        });

        emitter.emit(const _TestEvent('slow'));
        emitter.emit(_OtherEvent());
        await otherSeen.future;
      }, (error, _) => zoneErrors.add(error));

      expect(completed, ['slow', 'other']);
      expect(zoneErrors, isEmpty);
    });
  });
}
