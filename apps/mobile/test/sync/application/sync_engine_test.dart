import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketsync_mobile/core/database/app_database.dart';
import 'package:pocketsync_mobile/features/tasks/data/remote_task_models.dart';
import 'package:pocketsync_mobile/features/tasks/data/task_local_repository.dart';
import 'package:pocketsync_mobile/features/tasks/data/task_remote_api_client.dart';
import 'package:pocketsync_mobile/features/tasks/data/task_remote_exception.dart';
import 'package:pocketsync_mobile/features/tasks/domain/local_task_input.dart';
import 'package:pocketsync_mobile/sync/application/sync_engine.dart';
import 'package:pocketsync_mobile/sync/data/sync_operation_local_repository.dart';

void main() {
  late AppDatabase database;
  late TaskLocalRepository taskRepository;
  late SyncOperationLocalRepository operationRepository;
  late FakeTaskRemoteApiClient remoteClient;
  late SyncEngine syncEngine;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    taskRepository = TaskLocalRepository(database);
    operationRepository = SyncOperationLocalRepository(database);
    remoteClient = FakeTaskRemoteApiClient();
    syncEngine = SyncEngine(
      taskRepository: taskRepository,
      syncOperationRepository: operationRepository,
      remoteClient: remoteClient,
    );
  });

  tearDown(() async {
    await database.close();
  });

  test('syncs a pending create operation successfully', () async {
    final LocalTaskRow task = await taskRepository.createTask(
      const LocalTaskInput(title: 'Create remotely'),
      now: fixedTime(),
    );
    remoteClient.onCreate = (CreateRemoteTaskRequest request) async {
      expect(request.clientId, task.localId);
      expect(request.title, 'Create remotely');
      return remoteTask(id: 'remote-1', clientId: request.clientId, version: 1);
    };

    final SyncRunResult result = await syncEngine.runOnce();

    expect(result.processed, 1);
    expect(result.succeeded, 1);

    final LocalTaskRow synced = (await taskRepository.getByLocalId(
      task.localId,
    ))!;
    expect(synced.remoteId, 'remote-1');
    expect(synced.version, 1);
    expect(synced.syncStatus, taskSyncStatusSynced);

    final SyncOperationRow operation = (await allOperations(database)).last;
    expect(operation.status, syncOperationStatusCompleted);
  });

  test('processes create then update for the same task in order', () async {
    final LocalTaskRow task = await taskRepository.createTask(
      const LocalTaskInput(title: 'Draft'),
      now: fixedTime(),
    );
    await taskRepository.updateTask(
      localId: task.localId,
      input: const LocalTaskInput(title: 'Final'),
      now: fixedTime().add(const Duration(minutes: 1)),
    );
    remoteClient.onCreate = (CreateRemoteTaskRequest request) async {
      return remoteTask(id: 'remote-1', clientId: request.clientId, version: 1);
    };
    remoteClient.onUpdate = (String id, UpdateRemoteTaskRequest request) async {
      expect(id, 'remote-1');
      expect(request.title, 'Final');
      expect(request.expectedVersion, 1);
      return remoteTask(
        id: 'remote-1',
        clientId: task.localId,
        title: request.title,
        version: 2,
      );
    };

    final SyncRunResult result = await syncEngine.runOnce();

    expect(result.processed, 2);
    expect(result.succeeded, 2);
    expect(remoteClient.calls, <String>['create', 'update']);

    final LocalTaskRow synced = (await taskRepository.getByLocalId(
      task.localId,
    ))!;
    expect(synced.remoteId, 'remote-1');
    expect(synced.version, 2);
    expect(synced.syncStatus, taskSyncStatusSynced);
  });

  test('syncs a pending delete operation with tombstone data', () async {
    final LocalTaskRow task = await createSyncedTask(
      database: database,
      taskRepository: taskRepository,
      operationRepository: operationRepository,
    );
    final DateTime deletedAt = fixedTime().add(const Duration(minutes: 3));
    await taskRepository.softDeleteTask(localId: task.localId, now: deletedAt);
    remoteClient.onDelete = (String id, DeleteRemoteTaskRequest request) async {
      expect(id, 'remote-1');
      expect(request.expectedVersion, 1);
      expect(request.deletedAt, deletedAt);
      return remoteTask(
        id: 'remote-1',
        clientId: task.localId,
        version: 2,
        deletedAt: deletedAt,
      );
    };

    final SyncRunResult result = await syncEngine.runOnce();

    expect(result.processed, 1);
    expect(result.succeeded, 1);

    final LocalTaskRow deleted = (await taskRepository.getByLocalId(
      task.localId,
    ))!;
    expect(deleted.deletedAt?.toUtc(), deletedAt);
    expect(deleted.version, 2);
    expect(deleted.syncStatus, taskSyncStatusSynced);
    expect(await taskRepository.getActiveTasks(), isEmpty);
  });

  test('keeps retryable failures pending and increments attempts', () async {
    final LocalTaskRow task = await taskRepository.createTask(
      const LocalTaskInput(title: 'Retry later'),
      now: fixedTime(),
    );
    remoteClient.onCreate = (_) async => throw const TaskRemoteException(
      kind: TaskRemoteExceptionKind.timeout,
      message: 'request timed out',
    );

    final SyncRunResult result = await syncEngine.runOnce();

    expect(result.retryableFailures, 1);

    final SyncOperationRow operation = (await allOperations(database)).last;
    expect(operation.status, syncOperationStatusPending);
    expect(operation.attempts, 1);
    expect(operation.lastError, 'request timed out');

    final LocalTaskRow pending = (await taskRepository.getByLocalId(
      task.localId,
    ))!;
    expect(pending.syncStatus, taskSyncStatusPending);
    expect(pending.lastError, 'request timed out');
  });

  test(
    'syncs an edited task after its original create operation failed',
    () async {
      syncEngine = SyncEngine(
        taskRepository: taskRepository,
        syncOperationRepository: operationRepository,
        remoteClient: remoteClient,
        maxAttempts: 1,
      );
      final LocalTaskRow task = await taskRepository.createTask(
        const LocalTaskInput(title: 'Original title'),
        now: fixedTime(),
      );
      remoteClient.onCreate = (_) async => throw const TaskRemoteException(
        kind: TaskRemoteExceptionKind.network,
        message: 'network unavailable',
      );
      await syncEngine.runOnce();

      await taskRepository.updateTask(
        localId: task.localId,
        input: const LocalTaskInput(title: 'Latest title'),
        now: fixedTime().add(const Duration(minutes: 1)),
      );
      remoteClient.onCreate = (CreateRemoteTaskRequest request) async {
        expect(request.title, 'Latest title');
        return remoteTask(
          id: 'remote-1',
          clientId: request.clientId,
          version: 1,
        );
      };

      final SyncRunResult result = await syncEngine.runOnce();
      final LocalTaskRow synced = (await taskRepository.getByLocalId(
        task.localId,
      ))!;

      expect(result.succeeded, 1);
      expect(synced.remoteId, 'remote-1');
      expect(synced.syncStatus, taskSyncStatusSynced);
    },
  );

  test(
    'marks retryable failures as failed after the max attempt count',
    () async {
      syncEngine = SyncEngine(
        taskRepository: taskRepository,
        syncOperationRepository: operationRepository,
        remoteClient: remoteClient,
        maxAttempts: 1,
      );
      final LocalTaskRow task = await taskRepository.createTask(
        const LocalTaskInput(title: 'Give up after one try'),
        now: fixedTime(),
      );
      remoteClient.onCreate = (_) async => throw const TaskRemoteException(
        kind: TaskRemoteExceptionKind.network,
        message: 'network request failed',
      );

      final SyncRunResult result = await syncEngine.runOnce();

      expect(result.permanentFailures, 1);

      final SyncOperationRow operation = (await allOperations(database)).single;
      expect(operation.status, syncOperationStatusFailed);
      expect(operation.attempts, 1);

      final LocalTaskRow failed = (await taskRepository.getByLocalId(
        task.localId,
      ))!;
      expect(failed.syncStatus, taskSyncStatusFailed);
      expect(failed.lastError, 'network request failed');
    },
  );

  test('marks non-retryable failures as failed', () async {
    final LocalTaskRow task = await taskRepository.createTask(
      const LocalTaskInput(title: 'Validation failure'),
      now: fixedTime(),
    );
    remoteClient.onCreate = (_) async => throw const TaskRemoteException(
      kind: TaskRemoteExceptionKind.validation,
      message: 'title is required',
    );

    final SyncRunResult result = await syncEngine.runOnce();

    expect(result.permanentFailures, 1);

    final SyncOperationRow operation = (await allOperations(database)).last;
    expect(operation.status, syncOperationStatusFailed);

    final LocalTaskRow failed = (await taskRepository.getByLocalId(
      task.localId,
    ))!;
    expect(failed.syncStatus, taskSyncStatusFailed);
    expect(failed.lastError, 'title is required');
  });

  test('marks conflicts and stores the server version', () async {
    final LocalTaskRow task = await createSyncedTask(
      database: database,
      taskRepository: taskRepository,
      operationRepository: operationRepository,
    );
    await taskRepository.updateTask(
      localId: task.localId,
      input: const LocalTaskInput(title: 'Local edit'),
      now: fixedTime().add(const Duration(minutes: 1)),
    );
    remoteClient.onUpdate = (_, _) async => throw TaskRemoteException(
      kind: TaskRemoteExceptionKind.conflict,
      message: 'task has changed on the server',
      serverTask: remoteTask(
        id: 'remote-1',
        clientId: task.localId,
        title: 'Server edit',
        version: 3,
      ),
    );

    final SyncRunResult result = await syncEngine.runOnce();

    expect(result.conflicts, 1);

    final SyncOperationRow operation = (await allOperations(database)).last;
    expect(operation.status, syncOperationStatusFailed);

    final LocalTaskRow conflicted = (await taskRepository.getByLocalId(
      task.localId,
    ))!;
    expect(conflicted.syncStatus, taskSyncStatusConflict);
    expect(conflicted.version, 3);
    expect(conflicted.lastError, 'task has changed on the server');

    final TaskConflictSnapshot? conflict = await taskRepository
        .getConflictForTask(task.localId);
    expect(conflict == null, isFalse);
    expect(conflict!.title, 'Server edit');
    expect(conflict.version, 3);
  });

  test(
    'skips later operations for an entity after an earlier retryable failure',
    () async {
      final LocalTaskRow task = await taskRepository.createTask(
        const LocalTaskInput(title: 'Draft'),
        now: fixedTime(),
      );
      await taskRepository.updateTask(
        localId: task.localId,
        input: const LocalTaskInput(title: 'Final'),
        now: fixedTime().add(const Duration(minutes: 1)),
      );
      remoteClient.onCreate = (_) async => throw const TaskRemoteException(
        kind: TaskRemoteExceptionKind.timeout,
        message: 'request timed out',
      );

      final SyncRunResult result = await syncEngine.runOnce();

      expect(result.processed, 1);
      expect(result.retryableFailures, 1);
      expect(result.skippedOperations, 1);

      final List<SyncOperationRow> operations = await allOperations(database);
      expect(operations.first.status, syncOperationStatusPending);
      expect(operations.first.attempts, 1);
      expect(operations.last.status, syncOperationStatusPending);
      expect(operations.last.attempts, 0);
    },
  );

  test('prevents duplicate sync runs', () async {
    await taskRepository.createTask(
      const LocalTaskInput(title: 'Concurrent run'),
      now: fixedTime(),
    );
    final Completer<RemoteTask> remoteCompleter = Completer<RemoteTask>();
    remoteClient.onCreate = (CreateRemoteTaskRequest request) {
      return remoteCompleter.future;
    };

    final Future<SyncRunResult> firstRun = syncEngine.runOnce();
    final SyncRunResult secondRun = await syncEngine.runOnce();
    remoteCompleter.complete(remoteTask(id: 'remote-1'));
    final SyncRunResult firstResult = await firstRun;

    expect(secondRun.skipped, isTrue);
    expect(firstResult.succeeded, 1);
  });
}

Future<LocalTaskRow> createSyncedTask({
  required AppDatabase database,
  required TaskLocalRepository taskRepository,
  required SyncOperationLocalRepository operationRepository,
}) async {
  final LocalTaskRow created = await taskRepository.createTask(
    const LocalTaskInput(title: 'Already synced'),
    now: fixedTime(),
  );
  final SyncOperationRow createOperation = (await allOperations(
    database,
  )).single;
  await operationRepository.markCompleted(createOperation.id);
  await taskRepository.applyRemoteSyncResult(
    localId: created.localId,
    remoteId: 'remote-1',
    version: 1,
  );

  return (await taskRepository.getByLocalId(created.localId))!;
}

Future<List<SyncOperationRow>> allOperations(AppDatabase database) {
  final query = database.select(database.syncOperations)
    ..orderBy(<OrderingTerm Function($SyncOperationsTable)>[
      (table) => OrderingTerm.asc(table.createdAt),
      (table) => OrderingTerm.asc(table.id),
    ]);

  return query.get();
}

DateTime fixedTime() {
  return DateTime.utc(2026, 8, 14, 21);
}

RemoteTask remoteTask({
  String id = 'remote-1',
  String clientId = 'local-1',
  String title = 'Remote task',
  String description = '',
  bool completed = false,
  int version = 1,
  DateTime? deletedAt,
}) {
  return RemoteTask(
    id: id,
    clientId: clientId,
    title: title,
    description: description,
    completed: completed,
    version: version,
    createdAt: fixedTime(),
    updatedAt: fixedTime(),
    deletedAt: deletedAt,
  );
}

class FakeTaskRemoteApiClient implements TaskRemoteApiClient {
  final List<String> calls = <String>[];
  FutureOr<RemoteTask> Function(CreateRemoteTaskRequest request)? onCreate;
  FutureOr<List<RemoteTask>> Function({DateTime? since})? onList;
  FutureOr<RemoteTask> Function(String id)? onGet;
  FutureOr<RemoteTask> Function(String id, UpdateRemoteTaskRequest request)?
  onUpdate;
  FutureOr<RemoteTask> Function(String id, DeleteRemoteTaskRequest request)?
  onDelete;

  @override
  Future<RemoteTask> createTask(CreateRemoteTaskRequest request) async {
    calls.add('create');
    final handler = onCreate;
    if (handler == null) {
      return remoteTask(clientId: request.clientId);
    }

    return handler(request);
  }

  @override
  Future<List<RemoteTask>> listTasks({DateTime? since}) async {
    calls.add('list');
    final handler = onList;
    if (handler == null) {
      return <RemoteTask>[];
    }

    return handler(since: since);
  }

  @override
  Future<RemoteTask> getTask(String id) async {
    calls.add('get');
    final handler = onGet;
    if (handler == null) {
      return remoteTask(id: id);
    }

    return handler(id);
  }

  @override
  Future<RemoteTask> updateTask(
    String id,
    UpdateRemoteTaskRequest request,
  ) async {
    calls.add('update');
    final handler = onUpdate;
    if (handler == null) {
      return remoteTask(
        id: id,
        title: request.title,
        description: request.description,
        completed: request.completed,
        version: request.expectedVersion + 1,
      );
    }

    return handler(id, request);
  }

  @override
  Future<RemoteTask> deleteTask(
    String id,
    DeleteRemoteTaskRequest request,
  ) async {
    calls.add('delete');
    final handler = onDelete;
    if (handler == null) {
      return remoteTask(
        id: id,
        version: request.expectedVersion + 1,
        deletedAt: request.deletedAt,
      );
    }

    return handler(id, request);
  }
}
