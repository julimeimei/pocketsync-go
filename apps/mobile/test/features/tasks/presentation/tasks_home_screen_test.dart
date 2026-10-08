import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketsync_mobile/app/app.dart';
import 'package:pocketsync_mobile/core/database/app_database.dart';
import 'package:pocketsync_mobile/features/tasks/data/task_local_repository.dart';
import 'package:pocketsync_mobile/features/tasks/domain/local_task_input.dart';
import 'package:pocketsync_mobile/features/tasks/presentation/task_providers.dart';
import 'package:pocketsync_mobile/sync/application/network_status.dart';

void main() {
  testWidgets('shows the empty state when there are no local tasks', (
    WidgetTester tester,
  ) async {
    final FakeTaskRepository repository = FakeTaskRepository();
    addTearDown(repository.close);

    await pumpApp(tester, repository);

    expect(find.text('No tasks yet'), findsOneWidget);
    expect(find.text('0 pending'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
  });

  testWidgets('shows offline state and disables manual sync', (
    WidgetTester tester,
  ) async {
    final FakeTaskRepository repository = FakeTaskRepository();
    addTearDown(repository.close);

    await pumpApp(tester, repository, networkStatus: NetworkStatus.offline);

    expect(find.text('Offline'), findsOneWidget);

    final IconButton syncButton = tester.widget<IconButton>(
      find.byKey(const Key('sync.manual')),
    );
    expect(syncButton.onPressed, isNull);
  });

  testWidgets('creates a local task and shows its pending sync state', (
    WidgetTester tester,
  ) async {
    final FakeTaskRepository repository = FakeTaskRepository();
    addTearDown(repository.close);
    await pumpApp(tester, repository);

    await tester.tap(find.byKey(const Key('task.add')));
    await pumpUi(tester);
    await tester.enterText(
      find.byKey(const Key('task.titleField')),
      'Draft offline flow',
    );
    await tester.enterText(
      find.byKey(const Key('task.descriptionField')),
      'Created without a network call.',
    );
    await tester.tap(find.byKey(const Key('task.save')));
    await pumpUi(tester);

    expect(find.text('Draft offline flow'), findsOneWidget);
    expect(find.text('Created without a network call.'), findsOneWidget);
    expect(find.text('pending'), findsOneWidget);
    expect(find.text('1 pending'), findsOneWidget);
    expect(repository.operations, <String>[syncOperationTypeCreate]);
  });

  testWidgets('edits a local task and queues an update operation', (
    WidgetTester tester,
  ) async {
    final FakeTaskRepository repository = FakeTaskRepository(
      seedTasks: <LocalTaskRow>[taskRow(localId: 'local-1', title: 'Original')],
    );
    addTearDown(repository.close);
    await pumpApp(tester, repository);

    await tester.tap(find.byTooltip('Edit task'));
    await pumpUi(tester);
    await tester.enterText(
      find.byKey(const Key('task.titleField')),
      'Updated title',
    );
    await tester.tap(find.byKey(const Key('task.save')));
    await pumpUi(tester);

    expect(find.text('Updated title'), findsOneWidget);
    expect(find.text('Original'), findsNothing);
    expect(repository.operations, <String>[syncOperationTypeUpdate]);
  });

  testWidgets('toggles completion locally and keeps the task pending sync', (
    WidgetTester tester,
  ) async {
    final FakeTaskRepository repository = FakeTaskRepository(
      seedTasks: <LocalTaskRow>[
        taskRow(localId: 'local-1', title: 'Toggle me'),
      ],
    );
    addTearDown(repository.close);
    await pumpApp(tester, repository);

    await tester.tap(find.byKey(const Key('task.checkbox.local-1')));
    await pumpUi(tester);

    final LocalTaskRow? updated = await repository.getByLocalId('local-1');
    expect(updated, isNotNull);
    expect(updated!.completed, isTrue);
    expect(updated.syncStatus, taskSyncStatusPending);
    expect(repository.operations, <String>[syncOperationTypeUpdate]);
  });

  testWidgets('soft deletes a task after confirmation', (
    WidgetTester tester,
  ) async {
    final FakeTaskRepository repository = FakeTaskRepository(
      seedTasks: <LocalTaskRow>[
        taskRow(localId: 'local-1', title: 'Remove me'),
      ],
    );
    addTearDown(repository.close);
    await pumpApp(tester, repository);

    await tester.tap(find.byTooltip('Delete task'));
    await pumpUi(tester);
    await tester.tap(find.byKey(const Key('task.confirmDelete')));
    await pumpUi(tester);

    expect(find.text('Remove me'), findsNothing);
    expect(find.text('No tasks yet'), findsOneWidget);
    expect(repository.operations, <String>[syncOperationTypeDelete]);
  });

  testWidgets('resolves a conflict using the server version', (
    WidgetTester tester,
  ) async {
    final FakeTaskRepository repository = FakeTaskRepository(
      seedTasks: <LocalTaskRow>[
        taskRow(
          localId: 'local-1',
          remoteId: 'remote-1',
          title: 'Local edit',
          description: 'Local description',
          syncStatus: taskSyncStatusConflict,
          version: 2,
        ),
      ],
      seedConflicts: <String, TaskConflictSnapshot>{
        'local-1': TaskConflictSnapshot(
          remoteId: 'remote-1',
          title: 'Server edit',
          description: 'Server description',
          completed: true,
          version: 3,
          updatedAt: fixedTime().add(const Duration(minutes: 2)),
        ),
      },
    );
    addTearDown(repository.close);
    await pumpApp(tester, repository);

    await tester.tap(find.byKey(const Key('task.resolve.local-1')));
    await pumpUi(tester);

    expect(find.text('Resolve conflict'), findsOneWidget);
    expect(find.text('Local edit'), findsWidgets);
    expect(find.text('Server edit'), findsOneWidget);

    await tester.tap(find.byKey(const Key('conflict.useServer')));
    await pumpUi(tester);

    expect(find.text('Server edit'), findsOneWidget);
    expect(find.text('Local edit'), findsNothing);
    expect(find.text('synced'), findsOneWidget);
    expect(repository.resolutions, <String>['useServer']);
  });
}

Future<void> pumpApp(
  WidgetTester tester,
  FakeTaskRepository repository, {
  NetworkStatus networkStatus = NetworkStatus.online,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        taskLocalRepositoryProvider.overrideWithValue(repository),
        taskListProvider.overrideWith((ref) => repository.watchActiveTasks()),
        pendingSyncOperationCountProvider.overrideWith(
          (ref) => repository.watchPendingCount(),
        ),
        networkStatusProvider.overrideWith(
          (ref) => Stream.value(networkStatus),
        ),
      ],
      child: const PocketSyncApp(),
    ),
  );
  await pumpUi(tester);
}

Future<void> pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

LocalTaskRow taskRow({
  required String localId,
  required String title,
  String? remoteId,
  String description = '',
  bool completed = false,
  String syncStatus = taskSyncStatusPending,
  int? version,
  DateTime? updatedAt,
}) {
  final DateTime now = updatedAt ?? fixedTime();

  return LocalTaskRow(
    localId: localId,
    remoteId: remoteId,
    title: title,
    description: description,
    completed: completed,
    syncStatus: syncStatus,
    version: version,
    createdAt: now,
    updatedAt: now,
    deletedAt: null,
    lastError: null,
  );
}

DateTime fixedTime() {
  return DateTime.utc(2026, 8, 14, 21);
}

class FakeTaskRepository implements TaskRepository {
  FakeTaskRepository({
    List<LocalTaskRow> seedTasks = const <LocalTaskRow>[],
    Map<String, TaskConflictSnapshot> seedConflicts =
        const <String, TaskConflictSnapshot>{},
  }) : _tasks = List<LocalTaskRow>.of(seedTasks),
       _conflicts = Map<String, TaskConflictSnapshot>.of(seedConflicts);

  final StreamController<List<LocalTaskRow>> _tasksController =
      StreamController<List<LocalTaskRow>>.broadcast();
  final StreamController<int> _pendingCountController =
      StreamController<int>.broadcast();
  final List<String> operations = <String>[];
  final List<String> resolutions = <String>[];
  final List<LocalTaskRow> _tasks;
  final Map<String, TaskConflictSnapshot> _conflicts;
  int _nextId = 1;

  @override
  Stream<List<LocalTaskRow>> watchActiveTasks() async* {
    yield List<LocalTaskRow>.unmodifiable(_tasks);
    yield* _tasksController.stream;
  }

  Stream<int> watchPendingCount() async* {
    yield operations.length;
    yield* _pendingCountController.stream;
  }

  @override
  Future<List<LocalTaskRow>> getActiveTasks() async {
    return List<LocalTaskRow>.unmodifiable(_tasks);
  }

  @override
  Future<LocalTaskRow?> getByLocalId(String localId) async {
    return _tasks
        .where((LocalTaskRow task) => task.localId == localId)
        .firstOrNull;
  }

  @override
  Future<LocalTaskRow> createTask(LocalTaskInput input, {DateTime? now}) async {
    final DateTime timestamp = now ?? DateTime.utc(2026, 8, 14, 21, _nextId);
    final LocalTaskRow task = LocalTaskRow(
      localId: 'local-${_nextId++}',
      remoteId: null,
      title: input.title.trim(),
      description: input.description,
      completed: input.completed,
      syncStatus: taskSyncStatusPending,
      version: null,
      createdAt: timestamp,
      updatedAt: timestamp,
      deletedAt: null,
      lastError: null,
    );

    _tasks.insert(0, task);
    _recordOperation(syncOperationTypeCreate);
    _emitTasks();
    return task;
  }

  @override
  Future<LocalTaskRow> updateTask({
    required String localId,
    required LocalTaskInput input,
    DateTime? now,
  }) async {
    final int index = _tasks.indexWhere(
      (LocalTaskRow task) => task.localId == localId,
    );
    if (index == -1) {
      throw LocalTaskNotFoundException(localId);
    }

    final LocalTaskRow existing = _tasks[index];
    final LocalTaskRow updated = existing.copyWith(
      title: input.title.trim(),
      description: input.description,
      completed: input.completed,
      syncStatus: taskSyncStatusPending,
      updatedAt: now ?? existing.updatedAt.add(const Duration(minutes: 1)),
    );

    _tasks[index] = updated;
    _recordOperation(syncOperationTypeUpdate);
    _emitTasks();
    return updated;
  }

  @override
  Future<LocalTaskRow> softDeleteTask({
    required String localId,
    DateTime? now,
  }) async {
    final int index = _tasks.indexWhere(
      (LocalTaskRow task) => task.localId == localId,
    );
    if (index == -1) {
      throw LocalTaskNotFoundException(localId);
    }

    final LocalTaskRow deleted = _tasks
        .removeAt(index)
        .copyWith(
          deletedAt: drift.Value<DateTime?>(
            now ?? DateTime.utc(2026, 8, 14, 22),
          ),
        );

    _recordOperation(syncOperationTypeDelete);
    _emitTasks();
    return deleted;
  }

  @override
  Future<void> applyRemoteSyncResult({
    required String localId,
    required String remoteId,
    required int version,
  }) async {
    final int index = _tasks.indexWhere(
      (LocalTaskRow task) => task.localId == localId,
    );
    if (index == -1) {
      throw LocalTaskNotFoundException(localId);
    }

    _tasks[index] = _tasks[index].copyWith(
      remoteId: drift.Value<String?>(remoteId),
      version: drift.Value<int?>(version),
      syncStatus: taskSyncStatusSynced,
    );
    _emitTasks();
  }

  @override
  Future<void> applyRemoteDeleteSyncResult({
    required String localId,
    required String remoteId,
    required int version,
    required DateTime deletedAt,
  }) async {}

  @override
  Future<TaskConflictSnapshot?> getConflictForTask(String localId) async {
    return _conflicts[localId];
  }

  @override
  Future<void> resolveConflictKeepingLocal({
    required String localId,
    DateTime? now,
  }) async {
    final int index = _tasks.indexWhere(
      (LocalTaskRow task) => task.localId == localId,
    );
    if (index == -1) {
      throw LocalTaskNotFoundException(localId);
    }

    final LocalTaskRow task = _tasks[index].copyWith(
      syncStatus: taskSyncStatusPending,
      updatedAt: now ?? DateTime.utc(2026, 8, 14, 23),
      lastError: const drift.Value<String?>(null),
    );
    _tasks[index] = task;
    _conflicts.remove(localId);
    resolutions.add('keepLocal');
    _recordOperation(
      task.deletedAt == null
          ? syncOperationTypeUpdate
          : syncOperationTypeDelete,
    );
    _emitTasks();
  }

  @override
  Future<void> resolveConflictUsingServer({
    required String localId,
    DateTime? now,
  }) async {
    final TaskConflictSnapshot? conflict = _conflicts.remove(localId);
    if (conflict == null) {
      throw LocalTaskConflictNotFoundException(localId);
    }

    final int index = _tasks.indexWhere(
      (LocalTaskRow task) => task.localId == localId,
    );
    if (index == -1) {
      throw LocalTaskNotFoundException(localId);
    }

    _tasks[index] = _tasks[index].copyWith(
      remoteId: drift.Value<String?>(conflict.remoteId),
      title: conflict.title,
      description: conflict.description,
      completed: conflict.completed,
      syncStatus: taskSyncStatusSynced,
      version: drift.Value<int?>(conflict.version),
      updatedAt: conflict.updatedAt,
      deletedAt: drift.Value<DateTime?>(conflict.deletedAt),
      lastError: const drift.Value<String?>(null),
    );
    resolutions.add('useServer');
    _emitTasks();
  }

  Future<void> close() async {
    await _tasksController.close();
    await _pendingCountController.close();
  }

  void _recordOperation(String operationType) {
    operations.add(operationType);
    _pendingCountController.add(operations.length);
  }

  void _emitTasks() {
    _tasksController.add(List<LocalTaskRow>.unmodifiable(_tasks));
  }
}
