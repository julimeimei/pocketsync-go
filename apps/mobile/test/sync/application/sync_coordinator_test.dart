import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketsync_mobile/sync/application/network_status.dart';
import 'package:pocketsync_mobile/sync/application/sync_coordinator.dart';
import 'package:pocketsync_mobile/sync/application/sync_engine.dart';

void main() {
  test('runs a manual sync and stores the result', () async {
    final FakeSyncRunner runner = FakeSyncRunner(
      result: const SyncRunResult(processed: 2, succeeded: 2),
    );
    final ProviderContainer container = syncContainer(runner: runner);
    addTearDown(container.dispose);

    final SyncRunResult? result = await container
        .read(syncCoordinatorProvider.notifier)
        .sync();

    expect(runner.runCount, 1);
    expect(result, isNotNull);
    expect(result!.succeeded, 2);

    final SyncCoordinatorState state = container.read(syncCoordinatorProvider);
    expect(state.isSyncing, isFalse);
    expect(state.lastResult, result);
    expect(state.lastError, isNull);
    expect(state.lastTrigger, SyncTrigger.manual);
    expect(state.lastCompletedAt, isNotNull);
  });

  test('runs sync when connectivity changes from offline to online', () async {
    final StreamController<NetworkStatus> network =
        StreamController<NetworkStatus>.broadcast();
    final FakeSyncRunner runner = FakeSyncRunner();
    final ProviderContainer container = syncContainer(
      runner: runner,
      networkStream: network.stream,
    );
    addTearDown(container.dispose);
    addTearDown(network.close);

    container.listen<SyncCoordinatorState>(
      syncCoordinatorProvider,
      (_, _) {},
      fireImmediately: true,
    );

    network.add(NetworkStatus.offline);
    await pumpEventQueue();
    network.add(NetworkStatus.online);
    await pumpEventQueue(times: 3);

    expect(runner.runCount, 1);
    expect(
      container.read(syncCoordinatorProvider).lastTrigger,
      SyncTrigger.connectivity,
    );
  });

  test('does not run sync for the initial online connectivity event', () async {
    final FakeSyncRunner runner = FakeSyncRunner();
    final ProviderContainer container = syncContainer(
      runner: runner,
      networkStream: Stream<NetworkStatus>.value(NetworkStatus.online),
    );
    addTearDown(container.dispose);

    container.listen<SyncCoordinatorState>(
      syncCoordinatorProvider,
      (_, _) {},
      fireImmediately: true,
    );
    await pumpEventQueue(times: 3);

    expect(runner.runCount, 0);
  });

  test('prevents duplicate manual sync runs', () async {
    final Completer<SyncRunResult> completer = Completer<SyncRunResult>();
    final FakeSyncRunner runner = FakeSyncRunner(completer: completer);
    final ProviderContainer container = syncContainer(runner: runner);
    addTearDown(container.dispose);
    final SyncCoordinator coordinator = container.read(
      syncCoordinatorProvider.notifier,
    );

    final Future<SyncRunResult?> firstRun = coordinator.sync();
    await pumpEventQueue();
    final SyncRunResult? secondRun = await coordinator.sync();
    completer.complete(const SyncRunResult(processed: 1, succeeded: 1));
    final SyncRunResult? firstResult = await firstRun;

    expect(runner.runCount, 1);
    expect(secondRun, isNull);
    expect(firstResult, isNotNull);
    expect(container.read(syncCoordinatorProvider).isSyncing, isFalse);
  });

  test('stores a safe generic error when the sync runner throws', () async {
    final FakeSyncRunner runner = FakeSyncRunner(error: StateError('boom'));
    final ProviderContainer container = syncContainer(runner: runner);
    addTearDown(container.dispose);

    final SyncRunResult? result = await container
        .read(syncCoordinatorProvider.notifier)
        .sync();

    expect(result, isNull);
    expect(runner.runCount, 1);

    final SyncCoordinatorState state = container.read(syncCoordinatorProvider);
    expect(state.isSyncing, isFalse);
    expect(state.lastError, 'Could not sync tasks');
  });
}

ProviderContainer syncContainer({
  required SyncRunner runner,
  Stream<NetworkStatus>? networkStream,
}) {
  return ProviderContainer(
    overrides: [
      syncEngineProvider.overrideWithValue(runner),
      networkStatusProvider.overrideWith(
        (ref) => networkStream ?? Stream<NetworkStatus>.empty(),
      ),
    ],
  );
}

class FakeSyncRunner implements SyncRunner {
  FakeSyncRunner({
    this.result = const SyncRunResult(processed: 1, succeeded: 1),
    this.completer,
    this.error,
  });

  final SyncRunResult result;
  final Completer<SyncRunResult>? completer;
  final Object? error;
  int runCount = 0;

  @override
  Future<SyncRunResult> runOnce() {
    runCount++;

    final Object? failure = error;
    if (failure != null) {
      throw failure;
    }

    final Completer<SyncRunResult>? pending = completer;
    if (pending != null) {
      return pending.future;
    }

    return Future<SyncRunResult>.value(result);
  }
}
