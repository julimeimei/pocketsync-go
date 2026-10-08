import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketsync_mobile/core/database/app_database.dart';
import 'package:pocketsync_mobile/features/tasks/data/task_local_repository.dart';
import 'package:pocketsync_mobile/features/tasks/domain/local_task_input.dart';
import 'package:pocketsync_mobile/sync/data/sync_operation_local_repository.dart';

void main() {
  late AppDatabase database;
  late TaskLocalRepository taskRepository;
  late SyncOperationLocalRepository syncRepository;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    taskRepository = TaskLocalRepository(database);
    syncRepository = SyncOperationLocalRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('creates a local task and queues a create operation', () async {
    final DateTime now = fixedTime();

    final LocalTaskRow task = await taskRepository.createTask(
      const LocalTaskInput(title: '  Write local database tests  '),
      now: now,
    );

    expect(task.title, 'Write local database tests');
    expect(task.syncStatus, taskSyncStatusPending);
    expect(task.remoteId, isNull);
    expect(task.version, isNull);

    final List<SyncOperationRow> operations = await syncRepository
        .getPendingOperations();
    expect(operations, hasLength(1));
    expect(operations.single.entityType, syncOperationEntityTask);
    expect(operations.single.operationType, syncOperationTypeCreate);

    final Map<String, Object?> payload =
        jsonDecode(operations.single.payload) as Map<String, Object?>;
    expect(payload['local_id'], task.localId);
    expect(payload['title'], 'Write local database tests');
  });

  test('updates a task and queues an update operation', () async {
    final DateTime now = fixedTime();
    final LocalTaskRow created = await taskRepository.createTask(
      const LocalTaskInput(title: 'Draft'),
      now: now,
    );

    final LocalTaskRow updated = await taskRepository.updateTask(
      localId: created.localId,
      input: const LocalTaskInput(
        title: 'Final title',
        description: 'Ready for sync',
        completed: true,
      ),
      now: now.add(const Duration(minutes: 1)),
    );

    expect(updated.title, 'Final title');
    expect(updated.completed, isTrue);
    expect(updated.syncStatus, taskSyncStatusPending);

    final List<SyncOperationRow> operations = await syncRepository
        .getPendingOperations();
    expect(
      operations.map((SyncOperationRow row) => row.operationType),
      <String>[syncOperationTypeCreate, syncOperationTypeUpdate],
    );
  });

  test('soft deletes a task and hides it from active tasks', () async {
    final DateTime now = fixedTime();
    final LocalTaskRow created = await taskRepository.createTask(
      const LocalTaskInput(title: 'Delete me'),
      now: now,
    );

    final LocalTaskRow deleted = await taskRepository.softDeleteTask(
      localId: created.localId,
      now: now.add(const Duration(minutes: 2)),
    );

    expect(deleted.deletedAt, isNotNull);
    expect(await taskRepository.getActiveTasks(), isEmpty);

    final List<SyncOperationRow> operations = await syncRepository
        .getPendingOperations();
    expect(operations.last.operationType, syncOperationTypeDelete);
  });

  test(
    'retries a failed create with a new create operation after an edit',
    () async {
      final DateTime now = fixedTime();
      final LocalTaskRow created = await taskRepository.createTask(
        const LocalTaskInput(title: 'Retry me'),
        now: now,
      );
      final SyncOperationRow failedCreate =
          (await syncRepository.getPendingOperations()).single;
      await syncRepository.recordFailure(
        id: failedCreate.id,
        lastError: 'network unavailable',
        now: now.add(const Duration(minutes: 1)),
      );

      await taskRepository.updateTask(
        localId: created.localId,
        input: const LocalTaskInput(title: 'Retry me with latest changes'),
        now: now.add(const Duration(minutes: 2)),
      );

      final SyncOperationRow retriedCreate =
          (await syncRepository.getPendingOperations()).single;
      final Map<String, Object?> payload =
          jsonDecode(retriedCreate.payload) as Map<String, Object?>;

      expect(retriedCreate.operationType, syncOperationTypeCreate);
      expect(payload['title'], 'Retry me with latest changes');
    },
  );

  test('soft deletes a synced task and queues its remote version', () async {
    final DateTime now = fixedTime();
    final LocalTaskRow created = await taskRepository.createTask(
      const LocalTaskInput(title: 'Delete after syncing'),
      now: now,
    );
    final SyncOperationRow createOperation =
        (await syncRepository.getPendingOperations()).single;
    await syncRepository.markCompleted(createOperation.id, now: now);
    await taskRepository.applyRemoteSyncResult(
      localId: created.localId,
      remoteId: 'remote-1',
      version: 2,
    );

    final LocalTaskRow deleted = await taskRepository.softDeleteTask(
      localId: created.localId,
      now: now.add(const Duration(minutes: 1)),
    );

    expect(deleted.deletedAt, isNotNull);
    expect(deleted.remoteId, 'remote-1');
    expect(deleted.version, 2);
    expect(await taskRepository.getActiveTasks(), isEmpty);

    final List<SyncOperationRow> pending = await syncRepository
        .getPendingOperations();
    expect(pending, hasLength(1));
    expect(pending.single.operationType, syncOperationTypeDelete);

    final Map<String, Object?> payload =
        jsonDecode(pending.single.payload) as Map<String, Object?>;
    expect(payload['remote_id'], 'remote-1');
    expect(payload['version'], 2);
    expect(payload['deleted_at'], isNotNull);
  });

  test('applies remote sync result to a local task', () async {
    final DateTime now = fixedTime();
    final LocalTaskRow created = await taskRepository.createTask(
      const LocalTaskInput(title: 'Sync me'),
      now: now,
    );

    await taskRepository.applyRemoteSyncResult(
      localId: created.localId,
      remoteId: 'remote-1',
      version: 3,
    );

    final LocalTaskRow? synced = await taskRepository.getByLocalId(
      created.localId,
    );

    expect(synced, isNotNull);
    expect(synced!.remoteId, 'remote-1');
    expect(synced.version, 3);
    expect(synced.syncStatus, taskSyncStatusSynced);
  });

  test('stores server conflict data locally', () async {
    final LocalTaskRow task = await prepareConflictedTask(
      taskRepository: taskRepository,
      syncRepository: syncRepository,
    );

    final TaskConflictSnapshot? conflict = await taskRepository
        .getConflictForTask(task.localId);
    final LocalTaskRow? conflicted = await taskRepository.getByLocalId(
      task.localId,
    );

    expect(conflict, isNotNull);
    expect(conflict!.remoteId, 'remote-1');
    expect(conflict.title, 'Server title');
    expect(conflict.version, 3);
    expect(conflicted, isNotNull);
    expect(conflicted!.syncStatus, taskSyncStatusConflict);
    expect(conflicted.version, 3);
  });

  test('resolves a conflict by keeping local changes', () async {
    final LocalTaskRow task = await prepareConflictedTask(
      taskRepository: taskRepository,
      syncRepository: syncRepository,
    );

    await taskRepository.resolveConflictKeepingLocal(
      localId: task.localId,
      now: fixedTime().add(const Duration(minutes: 4)),
    );

    final LocalTaskRow? resolved = await taskRepository.getByLocalId(
      task.localId,
    );
    final TaskConflictSnapshot? conflict = await taskRepository
        .getConflictForTask(task.localId);
    final List<SyncOperationRow> pending = await syncRepository
        .getPendingOperations();
    final Map<String, Object?> payload =
        jsonDecode(pending.single.payload) as Map<String, Object?>;

    expect(resolved, isNotNull);
    expect(resolved!.title, 'Local title');
    expect(resolved.syncStatus, taskSyncStatusPending);
    expect(resolved.lastError, isNull);
    expect(conflict, isNull);
    expect(pending.single.operationType, syncOperationTypeUpdate);
    expect(payload['title'], 'Local title');
    expect(payload['version'], 3);
  });

  test('resolves a conflict by using the server version', () async {
    final LocalTaskRow task = await prepareConflictedTask(
      taskRepository: taskRepository,
      syncRepository: syncRepository,
    );

    await taskRepository.resolveConflictUsingServer(localId: task.localId);

    final LocalTaskRow? resolved = await taskRepository.getByLocalId(
      task.localId,
    );
    final TaskConflictSnapshot? conflict = await taskRepository
        .getConflictForTask(task.localId);
    final List<SyncOperationRow> pending = await syncRepository
        .getPendingOperations();

    expect(resolved, isNotNull);
    expect(resolved!.title, 'Server title');
    expect(resolved.description, 'Server description');
    expect(resolved.completed, isTrue);
    expect(resolved.remoteId, 'remote-1');
    expect(resolved.version, 3);
    expect(resolved.syncStatus, taskSyncStatusSynced);
    expect(resolved.lastError, isNull);
    expect(conflict, isNull);
    expect(pending, isEmpty);
  });

  test('records sync operation failure', () async {
    final DateTime now = fixedTime();
    await taskRepository.createTask(
      const LocalTaskInput(title: 'Retry later'),
      now: now,
    );

    final SyncOperationRow operation =
        (await syncRepository.getPendingOperations()).single;

    await syncRepository.recordFailure(
      id: operation.id,
      lastError: 'network unavailable',
      now: now.add(const Duration(minutes: 1)),
    );

    final List<SyncOperationRow> pending = await syncRepository
        .getPendingOperations();
    expect(pending, isEmpty);

    final List<SyncOperationRow> allOperations = await database
        .select(database.syncOperations)
        .get();
    expect(allOperations.single.status, syncOperationStatusFailed);
    expect(allOperations.single.attempts, 1);
    expect(allOperations.single.lastError, 'network unavailable');
  });

  test('throws when updating a missing local task', () async {
    expect(
      () => taskRepository.updateTask(
        localId: 'missing',
        input: const LocalTaskInput(title: 'Missing'),
        now: fixedTime(),
      ),
      throwsA(isA<LocalTaskNotFoundException>()),
    );
  });
}

DateTime fixedTime() {
  return DateTime.utc(2026, 8, 14, 21);
}

Future<LocalTaskRow> prepareConflictedTask({
  required TaskLocalRepository taskRepository,
  required SyncOperationLocalRepository syncRepository,
}) async {
  final DateTime now = fixedTime();
  final LocalTaskRow created = await taskRepository.createTask(
    const LocalTaskInput(title: 'Original'),
    now: now,
  );
  final SyncOperationRow createOperation =
      (await syncRepository.getPendingOperations()).single;
  await syncRepository.markCompleted(createOperation.id, now: now);
  await taskRepository.applyRemoteSyncResult(
    localId: created.localId,
    remoteId: 'remote-1',
    version: 1,
  );
  final LocalTaskRow updated = await taskRepository.updateTask(
    localId: created.localId,
    input: const LocalTaskInput(
      title: 'Local title',
      description: 'Local description',
    ),
    now: now.add(const Duration(minutes: 1)),
  );
  final SyncOperationRow updateOperation =
      (await syncRepository.getPendingOperations()).single;
  await syncRepository.recordFailure(
    id: updateOperation.id,
    lastError: 'task has changed on the server',
    now: now.add(const Duration(minutes: 2)),
  );
  await taskRepository.markTaskConflict(
    localId: updated.localId,
    lastError: 'task has changed on the server',
    serverVersion: 3,
    serverSnapshot: TaskConflictSnapshot(
      remoteId: 'remote-1',
      title: 'Server title',
      description: 'Server description',
      completed: true,
      version: 3,
      updatedAt: now.add(const Duration(minutes: 3)),
    ),
    now: now.add(const Duration(minutes: 2)),
  );

  return (await taskRepository.getByLocalId(updated.localId))!;
}
