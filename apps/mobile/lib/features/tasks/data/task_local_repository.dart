import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/local_task_input.dart';

class LocalTaskNotFoundException implements Exception {
  const LocalTaskNotFoundException(this.localId);

  final String localId;

  @override
  String toString() => 'Local task not found: $localId';
}

class LocalTaskConflictNotFoundException implements Exception {
  const LocalTaskConflictNotFoundException(this.localId);

  final String localId;

  @override
  String toString() => 'Local task conflict not found: $localId';
}

class TaskConflictSnapshot {
  const TaskConflictSnapshot({
    required this.remoteId,
    required this.title,
    required this.description,
    required this.completed,
    required this.version,
    required this.updatedAt,
    this.deletedAt,
  });

  factory TaskConflictSnapshot.fromRow(TaskConflictRow row) {
    return TaskConflictSnapshot(
      remoteId: row.remoteId,
      title: row.title,
      description: row.description,
      completed: row.completed,
      version: row.version,
      updatedAt: row.updatedAt,
      deletedAt: row.deletedAt,
    );
  }

  final String remoteId;
  final String title;
  final String description;
  final bool completed;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

abstract interface class TaskRepository {
  Stream<List<LocalTaskRow>> watchActiveTasks();

  Future<List<LocalTaskRow>> getActiveTasks();

  Future<LocalTaskRow?> getByLocalId(String localId);

  Future<LocalTaskRow> createTask(LocalTaskInput input, {DateTime? now});

  Future<LocalTaskRow> updateTask({
    required String localId,
    required LocalTaskInput input,
    DateTime? now,
  });

  Future<LocalTaskRow> softDeleteTask({required String localId, DateTime? now});

  Future<void> applyRemoteSyncResult({
    required String localId,
    required String remoteId,
    required int version,
  });

  Future<void> applyRemoteDeleteSyncResult({
    required String localId,
    required String remoteId,
    required int version,
    required DateTime deletedAt,
  });

  Future<TaskConflictSnapshot?> getConflictForTask(String localId);

  Future<void> resolveConflictKeepingLocal({
    required String localId,
    DateTime? now,
  });

  Future<void> resolveConflictUsingServer({
    required String localId,
    DateTime? now,
  });
}

class TaskLocalRepository implements TaskRepository {
  TaskLocalRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  @override
  Stream<List<LocalTaskRow>> watchActiveTasks() {
    return _database.taskDao.watchActiveTasks();
  }

  @override
  Future<List<LocalTaskRow>> getActiveTasks() {
    return _database.taskDao.getActiveTasks();
  }

  @override
  Future<LocalTaskRow?> getByLocalId(String localId) {
    return _database.taskDao.getByLocalId(localId);
  }

  @override
  Future<LocalTaskRow> createTask(LocalTaskInput input, {DateTime? now}) async {
    final DateTime timestamp = now ?? DateTime.now().toUtc();
    final String localId = _uuid.v4();

    return _database.transaction(() async {
      final LocalTasksCompanion task = LocalTasksCompanion.insert(
        localId: localId,
        title: _cleanTitle(input.title),
        description: _cleanDescription(input.description),
        completed: Value<bool>(input.completed),
        syncStatus: const Value<String>(taskSyncStatusPending),
        createdAt: timestamp,
        updatedAt: timestamp,
      );

      await _database.taskDao.upsertTask(task);
      final LocalTaskRow created = (await _database.taskDao.getByLocalId(
        localId,
      ))!;

      await _enqueueTaskOperation(
        localId: localId,
        operationType: syncOperationTypeCreate,
        payload: _taskPayload(created),
        now: timestamp,
      );

      return created;
    });
  }

  @override
  Future<LocalTaskRow> updateTask({
    required String localId,
    required LocalTaskInput input,
    DateTime? now,
  }) async {
    final DateTime timestamp = now ?? DateTime.now().toUtc();

    return _database.transaction(() async {
      final LocalTaskRow existing = await _requireTask(localId);
      final LocalTaskRow updated = existing.copyWith(
        title: _cleanTitle(input.title),
        description: _cleanDescription(input.description),
        completed: input.completed,
        syncStatus: taskSyncStatusPending,
        updatedAt: timestamp,
        lastError: const Value<String?>(null),
      );

      await _database.taskDao.updateTask(
        LocalTasksCompanion(
          localId: Value<String>(updated.localId),
          remoteId: Value<String?>(updated.remoteId),
          title: Value<String>(updated.title),
          description: Value<String>(updated.description),
          completed: Value<bool>(updated.completed),
          syncStatus: Value<String>(updated.syncStatus),
          version: Value<int?>(updated.version),
          createdAt: Value<DateTime>(updated.createdAt),
          updatedAt: Value<DateTime>(updated.updatedAt),
          deletedAt: Value<DateTime?>(updated.deletedAt),
          lastError: Value<String?>(updated.lastError),
        ),
      );
      await _database.taskConflictDao.deleteByTaskLocalId(localId);

      final bool hasActiveCreateOperation = await _database.syncOperationDao
          .hasActiveCreateOperation(localId);
      final String operationType =
          updated.remoteId == null && !hasActiveCreateOperation
          ? syncOperationTypeCreate
          : syncOperationTypeUpdate;

      await _enqueueTaskOperation(
        localId: localId,
        operationType: operationType,
        payload: _taskPayload(updated),
        now: timestamp,
      );

      return updated;
    });
  }

  @override
  Future<LocalTaskRow> softDeleteTask({
    required String localId,
    DateTime? now,
  }) async {
    final DateTime timestamp = now ?? DateTime.now().toUtc();

    return _database.transaction(() async {
      final LocalTaskRow existing = await _requireTask(localId);
      final LocalTaskRow deleted = existing.copyWith(
        syncStatus: taskSyncStatusPending,
        updatedAt: timestamp,
        deletedAt: Value<DateTime?>(timestamp),
        lastError: const Value<String?>(null),
      );

      await _database.taskDao.updateTask(
        LocalTasksCompanion(
          localId: Value<String>(deleted.localId),
          remoteId: Value<String?>(deleted.remoteId),
          title: Value<String>(deleted.title),
          description: Value<String>(deleted.description),
          completed: Value<bool>(deleted.completed),
          syncStatus: Value<String>(deleted.syncStatus),
          version: Value<int?>(deleted.version),
          createdAt: Value<DateTime>(deleted.createdAt),
          updatedAt: Value<DateTime>(deleted.updatedAt),
          deletedAt: Value<DateTime?>(deleted.deletedAt),
          lastError: Value<String?>(deleted.lastError),
        ),
      );
      await _database.taskConflictDao.deleteByTaskLocalId(localId);

      await _enqueueTaskOperation(
        localId: localId,
        operationType: syncOperationTypeDelete,
        payload: _taskPayload(deleted),
        now: timestamp,
      );

      return deleted;
    });
  }

  @override
  Future<void> applyRemoteSyncResult({
    required String localId,
    required String remoteId,
    required int version,
  }) async {
    final LocalTaskRow existing = await _requireTask(localId);

    await _database.transaction(() async {
      await _database.taskDao.updateTask(
        LocalTasksCompanion(
          localId: Value<String>(existing.localId),
          remoteId: Value<String?>(remoteId),
          title: Value<String>(existing.title),
          description: Value<String>(existing.description),
          completed: Value<bool>(existing.completed),
          syncStatus: const Value<String>(taskSyncStatusSynced),
          version: Value<int?>(version),
          createdAt: Value<DateTime>(existing.createdAt),
          updatedAt: Value<DateTime>(existing.updatedAt),
          deletedAt: Value<DateTime?>(existing.deletedAt),
          lastError: const Value<String?>(null),
        ),
      );
      await _database.taskConflictDao.deleteByTaskLocalId(localId);
    });
  }

  @override
  Future<void> applyRemoteDeleteSyncResult({
    required String localId,
    required String remoteId,
    required int version,
    required DateTime deletedAt,
  }) async {
    final LocalTaskRow existing = await _requireTask(localId);

    await _database.transaction(() async {
      await _database.taskDao.updateTask(
        _taskUpdateCompanion(
          existing.copyWith(
            remoteId: Value<String?>(remoteId),
            syncStatus: taskSyncStatusSynced,
            version: Value<int?>(version),
            deletedAt: Value<DateTime?>(deletedAt),
            lastError: const Value<String?>(null),
          ),
        ),
      );
      await _database.taskConflictDao.deleteByTaskLocalId(localId);
    });
  }

  @override
  Future<TaskConflictSnapshot?> getConflictForTask(String localId) async {
    final TaskConflictRow? row = await _database.taskConflictDao
        .getByTaskLocalId(localId);
    if (row == null) {
      return null;
    }

    return TaskConflictSnapshot.fromRow(row);
  }

  @override
  Future<void> resolveConflictKeepingLocal({
    required String localId,
    DateTime? now,
  }) async {
    final DateTime timestamp = now ?? DateTime.now().toUtc();

    await _database.transaction(() async {
      final LocalTaskRow existing = await _requireTask(localId);
      final LocalTaskRow pending = existing.copyWith(
        syncStatus: taskSyncStatusPending,
        updatedAt: timestamp,
        lastError: const Value<String?>(null),
      );
      final String operationType = pending.deletedAt == null
          ? syncOperationTypeUpdate
          : syncOperationTypeDelete;

      await _database.taskDao.updateTask(_taskUpdateCompanion(pending));
      await _database.taskConflictDao.deleteByTaskLocalId(localId);
      await _enqueueTaskOperation(
        localId: localId,
        operationType: operationType,
        payload: _taskPayload(pending),
        now: timestamp,
      );
    });
  }

  @override
  Future<void> resolveConflictUsingServer({
    required String localId,
    DateTime? now,
  }) async {
    await _database.transaction(() async {
      final LocalTaskRow existing = await _requireTask(localId);
      final TaskConflictRow? conflict = await _database.taskConflictDao
          .getByTaskLocalId(localId);
      if (conflict == null) {
        throw LocalTaskConflictNotFoundException(localId);
      }

      await _database.taskDao.updateTask(
        LocalTasksCompanion(
          localId: Value<String>(existing.localId),
          remoteId: Value<String?>(conflict.remoteId),
          title: Value<String>(conflict.title),
          description: Value<String>(conflict.description),
          completed: Value<bool>(conflict.completed),
          syncStatus: const Value<String>(taskSyncStatusSynced),
          version: Value<int?>(conflict.version),
          createdAt: Value<DateTime>(existing.createdAt),
          updatedAt: Value<DateTime>(conflict.updatedAt),
          deletedAt: Value<DateTime?>(conflict.deletedAt),
          lastError: const Value<String?>(null),
        ),
      );
      await _database.taskConflictDao.deleteByTaskLocalId(localId);
    });
  }

  Future<void> markTaskSyncing(String localId, {DateTime? now}) async {
    final LocalTaskRow existing = await _requireTask(localId);

    await _database.taskDao.updateTask(
      _taskUpdateCompanion(
        existing.copyWith(
          syncStatus: taskSyncStatusSyncing,
          updatedAt: now ?? existing.updatedAt,
          lastError: const Value<String?>(null),
        ),
      ),
    );
  }

  Future<void> markTaskPending({
    required String localId,
    required String lastError,
    DateTime? now,
  }) async {
    final LocalTaskRow existing = await _requireTask(localId);

    await _database.taskDao.updateTask(
      _taskUpdateCompanion(
        existing.copyWith(
          syncStatus: taskSyncStatusPending,
          updatedAt: now ?? existing.updatedAt,
          lastError: Value<String?>(lastError),
        ),
      ),
    );
  }

  Future<void> markTaskFailed({
    required String localId,
    required String lastError,
    DateTime? now,
  }) async {
    final LocalTaskRow existing = await _requireTask(localId);

    await _database.taskDao.updateTask(
      _taskUpdateCompanion(
        existing.copyWith(
          syncStatus: taskSyncStatusFailed,
          updatedAt: now ?? existing.updatedAt,
          lastError: Value<String?>(lastError),
        ),
      ),
    );
  }

  Future<void> markTaskConflict({
    required String localId,
    required String lastError,
    int? serverVersion,
    TaskConflictSnapshot? serverSnapshot,
    DateTime? now,
  }) async {
    final LocalTaskRow existing = await _requireTask(localId);

    await _database.transaction(() async {
      await _database.taskDao.updateTask(
        _taskUpdateCompanion(
          existing.copyWith(
            syncStatus: taskSyncStatusConflict,
            version: Value<int?>(serverVersion ?? existing.version),
            updatedAt: now ?? existing.updatedAt,
            lastError: Value<String?>(lastError),
          ),
        ),
      );

      final TaskConflictSnapshot? snapshot = serverSnapshot;
      if (snapshot != null) {
        await _database.taskConflictDao.upsertConflict(
          TaskConflictsCompanion.insert(
            taskLocalId: localId,
            remoteId: snapshot.remoteId,
            title: snapshot.title,
            description: snapshot.description,
            completed: snapshot.completed,
            version: snapshot.version,
            updatedAt: snapshot.updatedAt,
            deletedAt: Value<DateTime?>(snapshot.deletedAt),
            storedAt: now ?? DateTime.now().toUtc(),
          ),
        );
      }
    });
  }

  LocalTasksCompanion _taskUpdateCompanion(LocalTaskRow task) {
    return LocalTasksCompanion(
      localId: Value<String>(task.localId),
      remoteId: Value<String?>(task.remoteId),
      title: Value<String>(task.title),
      description: Value<String>(task.description),
      completed: Value<bool>(task.completed),
      syncStatus: Value<String>(task.syncStatus),
      version: Value<int?>(task.version),
      createdAt: Value<DateTime>(task.createdAt),
      updatedAt: Value<DateTime>(task.updatedAt),
      deletedAt: Value<DateTime?>(task.deletedAt),
      lastError: Value<String?>(task.lastError),
    );
  }

  Future<LocalTaskRow> _requireTask(String localId) async {
    final LocalTaskRow? task = await _database.taskDao.getByLocalId(localId);
    if (task == null) {
      throw LocalTaskNotFoundException(localId);
    }

    return task;
  }

  Future<void> _enqueueTaskOperation({
    required String localId,
    required String operationType,
    required Map<String, Object?> payload,
    required DateTime now,
  }) {
    return _database.syncOperationDao.enqueue(
      SyncOperationsCompanion.insert(
        id: _uuid.v4(),
        entityType: syncOperationEntityTask,
        entityLocalId: localId,
        operationType: operationType,
        payload: jsonEncode(payload),
        status: const Value<String>(syncOperationStatusPending),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Map<String, Object?> _taskPayload(LocalTaskRow task) {
    return <String, Object?>{
      'local_id': task.localId,
      'remote_id': task.remoteId,
      'title': task.title,
      'description': task.description,
      'completed': task.completed,
      'version': task.version,
      'updated_at': task.updatedAt.toIso8601String(),
      'deleted_at': task.deletedAt?.toIso8601String(),
    };
  }

  String _cleanTitle(String title) {
    final String cleaned = title.trim();
    if (cleaned.isEmpty) {
      throw const FormatException('title is required');
    }
    if (cleaned.length > 200) {
      throw const FormatException('title must be at most 200 characters');
    }

    return cleaned;
  }

  String _cleanDescription(String description) {
    if (description.length > 2000) {
      throw const FormatException(
        'description must be at most 2000 characters',
      );
    }

    return description;
  }
}
