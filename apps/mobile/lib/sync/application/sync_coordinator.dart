import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_status.dart';
import 'sync_engine.dart';

final NotifierProvider<SyncCoordinator, SyncCoordinatorState>
syncCoordinatorProvider =
    NotifierProvider<SyncCoordinator, SyncCoordinatorState>(
      SyncCoordinator.new,
    );

enum SyncTrigger { manual, connectivity }

class SyncCoordinatorState {
  const SyncCoordinatorState({
    this.isSyncing = false,
    this.lastResult,
    this.lastError,
    this.lastCompletedAt,
    this.lastTrigger,
  });

  final bool isSyncing;
  final SyncRunResult? lastResult;
  final String? lastError;
  final DateTime? lastCompletedAt;
  final SyncTrigger? lastTrigger;

  SyncCoordinatorState copyWith({
    bool? isSyncing,
    Object? lastResult = _unchanged,
    Object? lastError = _unchanged,
    Object? lastCompletedAt = _unchanged,
    Object? lastTrigger = _unchanged,
  }) {
    return SyncCoordinatorState(
      isSyncing: isSyncing ?? this.isSyncing,
      lastResult: identical(lastResult, _unchanged)
          ? this.lastResult
          : lastResult as SyncRunResult?,
      lastError: identical(lastError, _unchanged)
          ? this.lastError
          : lastError as String?,
      lastCompletedAt: identical(lastCompletedAt, _unchanged)
          ? this.lastCompletedAt
          : lastCompletedAt as DateTime?,
      lastTrigger: identical(lastTrigger, _unchanged)
          ? this.lastTrigger
          : lastTrigger as SyncTrigger?,
    );
  }
}

class SyncCoordinator extends Notifier<SyncCoordinatorState> {
  @override
  SyncCoordinatorState build() {
    ref.listen<AsyncValue<NetworkStatus>>(networkStatusProvider, (
      AsyncValue<NetworkStatus>? previous,
      AsyncValue<NetworkStatus> next,
    ) {
      final NetworkStatus? previousStatus = previous?.value;
      final NetworkStatus? nextStatus = next.value;

      if (previousStatus == NetworkStatus.offline &&
          nextStatus == NetworkStatus.online) {
        unawaited(sync(trigger: SyncTrigger.connectivity));
      }
    });

    return const SyncCoordinatorState();
  }

  Future<SyncRunResult?> sync({
    SyncTrigger trigger = SyncTrigger.manual,
  }) async {
    if (state.isSyncing) {
      return null;
    }

    state = state.copyWith(
      isSyncing: true,
      lastResult: null,
      lastError: null,
      lastTrigger: trigger,
    );

    try {
      final SyncRunResult result = await ref.read(syncEngineProvider).runOnce();
      state = state.copyWith(
        isSyncing: false,
        lastResult: result,
        lastCompletedAt: DateTime.now().toUtc(),
        lastTrigger: trigger,
      );

      return result;
    } on Object {
      state = state.copyWith(
        isSyncing: false,
        lastResult: null,
        lastError: 'Could not sync tasks',
        lastCompletedAt: DateTime.now().toUtc(),
        lastTrigger: trigger,
      );

      return null;
    }
  }
}

const Object _unchanged = Object();
