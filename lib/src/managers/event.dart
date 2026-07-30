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
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart' as sync;

import '../events.dart';
import '../exceptions.dart';
import '../extensions.dart';
import '../logger.dart';
import '../support/disposable.dart';
import '../types/other.dart';

mixin EventsEmittable<T> {
  final events = EventsEmitter<T>();
  EventsListener<T> createListener({bool synchronized = false}) =>
      EventsListener<T>(events, synchronized: synchronized);
}

// Type-safe, multi-listenable, dispose safe event handling
// TODO: Move to a separate package

class EventsEmitter<T> extends EventsListenable<T> {
  // suppport for multiple event listeners
  final streamCtrl = StreamController<T>.broadcast(sync: false);

  bool _queueMode = false;
  final _queue = Queue<T>();

  EventsEmitter({
    bool listenSynchronized = false,
  }) : super(synchronized: listenSynchronized) {
    // clean up
    onDispose(() async => await streamCtrl.close());
  }

  @override
  EventsEmitter<T> get emitter => this;

  @internal
  void emit(T event) {
    // check if already disposed
    if (isDisposed) {
      logger.warning('failed to emit event ${event} on a disposed emitter');
      return;
    }

    if (logger.isLoggable(Level.FINEST)) {
      final scope = event is InternalEvent ? 'internal' : 'public';
      logger.finest('[${objectId}] emit ($scope) $event');
    }

    // queue mode
    if (_queueMode) {
      _queue.add(event);
      return;
    }
    // emit the event
    streamCtrl.add(event);
  }

  @internal
  void updateQueueMode(bool newValue, {bool shouldEmitQueued = true}) {
    // check if already disposed
    if (isDisposed) {
      logger.warning('failed to update queueMode on a disposed emitter');
      return;
    }
    if (_queueMode == newValue) return;
    _queueMode = newValue;
    if (!_queueMode && shouldEmitQueued) emitQueued();
  }

  @internal
  void emitQueued() {
    while (_queue.isNotEmpty) {
      final event = _queue.removeFirst();
      // emit the event
      streamCtrl.add(event);
    }
  }
}

// for listening only
class EventsListener<T> extends EventsListenable<T> {
  @override
  final EventsEmitter<T> emitter;

  EventsListener(
    this.emitter, {
    bool synchronized = false,
  }) : super(
          synchronized: synchronized,
        );
}

// ensures all listeners will close on dispose
abstract class EventsListenable<T> extends Disposable {
  // the emitter to listen to
  EventsEmitter<T> get emitter;

  final bool synchronized;
  // keep track of listeners to cancel later
  final _listeners = <StreamSubscription<T>>[];
  final _syncLock = sync.Lock();

  List<StreamSubscription<T>> get listeners => _listeners;

  EventsListenable({
    required this.synchronized,
  }) {
    onDispose(() async {
      await cancelAll();
    });
  }

  Future<void> cancelAll() async {
    if (_listeners.isNotEmpty) {
      // Stop listening to all events
      logger.finer('${objectId} cancelling ${_listeners.length} listeners(s)');
      final listenersCopy = List.of(_listeners);
      _listeners.clear();
      for (final listener in listenersCopy) {
        await listener.cancel();
      }
    }
  }

  // listens to all events, guaranteed to be cancelled on dispose
  CancelListenFunc listen(FutureOr<void> Function(T) onEvent) {
    // `Stream.listen` discards whatever the handler returns, so an error
    // escaping an async handler is delivered to the root zone as an uncaught
    // application error instead of an SDK one. There is nothing to propagate it
    // to — the event has already been dispatched and no caller is waiting — so
    // report it here and keep the subscription and the emitter alive.
    FutureOr<void> guarded(T event) async {
      try {
        await onEvent(event);
      } catch (error, stackTrace) {
        logger.severe('${objectId} listener for ${event.runtimeType} failed', error, stackTrace);
      }
    }

    FutureOr<void> Function(T) func = guarded;
    if (synchronized) {
      // ensure `onEvent` will trigger one by one (waits for previous `onEvent` to complete)
      func = (event) async {
        await _syncLock.synchronized(() async {
          await guarded(event);
        });
      };
    }

    final listener = emitter.streamCtrl.stream.listen(func);
    _listeners.add(listener);

    // make a cancel func to cancel listening and remove from list in 1 call
    cancelFunc() async {
      await listener.cancel();
      _listeners.remove(listener);
      logger.fine('${objectId} event was cancelled by func');
    }

    return cancelFunc;
  }

  // convenience method to listen & filter a specific event type
  CancelListenFunc on<E>(
    FutureOr<void> Function(E) then, {
    bool Function(E)? filter,
  }) =>
      listen((event) async {
        // event must be E
        if (event is! E) return;
        // filter must be true (if filter is used)
        if (filter != null && !filter(event)) return;
        // cast to E
        await then(event);
      });

  /// convenience method to listen & filter a specific event type, just once.
  CancelListenFunc? once<E>(
    FutureOr<void> Function(E) then, {
    bool Function(E)? filter,
  }) {
    CancelListenFunc? cancelFunc;
    cancelFunc = listen((event) async {
      // event must be E
      if (event is! E) return;
      // filter must be true (if filter is used)
      if (filter != null && !filter(event)) return;
      // cast to E
      await then(event);
      // cancel after 1 event
      await cancelFunc?.call();
    });
    return cancelFunc;
  }

  // waits for a specific event type
  Future<E> waitFor<E>({
    required Duration duration,
    bool Function(E)? filter,
    FutureOr<E> Function()? onTimeout,
  }) async {
    final completer = Completer<E>();

    final cancelFunc = on<E>(
      (event) {
        if (!completer.isCompleted) {
          completer.complete(event);
        }
      },
      filter: filter,
    );

    try {
      // wait to complete with timeout
      return await completer.future.timeout(
        duration,
        onTimeout: onTimeout ?? () => throw TimeoutException(),
      );
      // do not catch exceptions and pass it up
    } finally {
      // always clean-up listener
      await cancelFunc.call();
    }
  }
}
