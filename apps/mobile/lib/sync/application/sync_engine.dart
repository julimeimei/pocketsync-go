import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/database_provider.dart';
import '../../features/tasks/data/remote_task_models.dart';
import '../../features/tasks/data/task_local_repository.dart';
import '../../features/tasks/data/task_remote_api_client.dart';
import '../../features/tasks/data/task_remote_exception.dart';
import '../data/sync_operation_local_repository.dart';

const int defaultSyncMaxAttempts = 3;

final Provider<SyncRunner> syncEngineProvider = Provider<SyncRunner>((ref) {
  final AppDatabase database = ref.watch(appDatabaseProvider);

  return SyncEngine(
    taskRepository: TaskLocalRepository(database),
    syncOperationRepository: SyncOperationLocalRepository(database),
    remoteClient: ref.watch(taskRemoteApiClientProvider),
  );
});

abstract interface class SyncRunner {
  Future<SyncRunResult> runOnce();
}

class SyncEngine implements SyncRunner {
  SyncEngine({
    required this.taskRepository,
    required this.syncOperationRepository,
    required this.remoteClient,
    this.maxAttempts = defaultSyncMaxAttempts,
  });

  final TaskLocalRepository taskRepository;
  final SyncOperationLocalRepository syncOperationRepository;
  final TaskRemoteApiClient remoteClient;
  final int maxAttempts;
  bool _isRunning = false;

  @override
  Future<SyncRunResult> runOnce() async {
    if (_isRunning) {
      return const SyncRunResult(skipped: true);
    }

    _isRunning = true;
    final SyncRunResultBuilder result = SyncRunResultBuilder();
    final Set<String> blockedLocalIds = <String>{};

    try {
      final List<SyncOperationRow> operations = await syncOperationRepository
          .getPendingOperations();

      for (final SyncOperationRow operation in operations) {
        if (blockedLocalIds.contains(operation.entityLocalId)) {
          result.skippedOperations++;
          continue;
        }

        final SyncOperationOutcome outcome = await _processOperation(operation);
        result.record(outcome);

        if (outcome.blocksRemainingEntityOperations) {
          blockedLocalIds.add(operation.entityLocalId);
        }
      }

      return result.build();
    } finally {
      _isRunning = false;
    }
  }

  Future<SyncOperationOutcome> _processOperation(
    SyncOperationRow operation,
  ) async {
    if (operation.entityType != syncOperationEntityTask) {
      await syncOperationRepository.recordFailure(
        id: operation.id,
        lastError: 'unsupported sync entity',
      );
      return SyncOperationOutcome.permanentFailure;
    }

    final LocalTaskRow? task = await taskRepository.getByLocalId(
      operation.entityLocalId,
    );
    if (task == null) {
      await syncOperationRepository.recordFailure(
        id: operation.id,
        lastError: 'local task no longer exists',
      );
      return SyncOperationOutcome.permanentFailure;
    }

    await syncOperationRepository.markSyncing(operation.id);
    await taskRepository.markTaskSyncing(operation.entityLocalId);

    try {
      final _TaskSyncPayload payload = _TaskSyncPayload.fromOperation(
        operation,
      );
      final RemoteTask remoteTask = await _sendOperation(
        operation: operation,
        task: task,
        payload: payload,
      );

      if (operation.operationType == syncOperationTypeDelete) {
        await taskRepository.applyRemoteDeleteSyncResult(
          localId: operation.entityLocalId,
          remoteId: remoteTask.id,
          version: remoteTask.version,
          deletedAt: payload.deletedAt ?? _requireDeletedAt(task),
        );
      } else {
        await taskRepository.applyRemoteSyncResult(
          localId: operation.entityLocalId,
          remoteId: remoteTask.id,
          version: remoteTask.version,
        );
      }
      await syncOperationRepository.markCompleted(operation.id);
      return SyncOperationOutcome.success;
    } on TaskRemoteException catch (error) {
      return _handleRemoteException(operation, error);
    } on FormatException catch (error) {
      return _markPermanentFailure(
        operation,
        _safeMessage(error.message, fallback: 'invalid sync payload'),
      );
    }
  }

  Future<RemoteTask> _sendOperation({
    required SyncOperationRow operation,
    required LocalTaskRow task,
    required _TaskSyncPayload payload,
  }) {
    return switch (operation.operationType) {
      syncOperationTypeCreate => remoteClient.createTask(
        CreateRemoteTaskRequest(
          clientId: payload.localId,
          title: payload.title,
          description: payload.description,
          completed: payload.completed,
          updatedAt: payload.updatedAt,
        ),
      ),
      syncOperationTypeUpdate => remoteClient.updateTask(
        _requireRemoteId(task),
        UpdateRemoteTaskRequest(
          title: payload.title,
          description: payload.description,
          completed: payload.completed,
          expectedVersion: _requireVersion(task),
          updatedAt: payload.updatedAt,
        ),
      ),
      syncOperationTypeDelete => remoteClient.deleteTask(
        _requireRemoteId(task),
        DeleteRemoteTaskRequest(
          expectedVersion: _requireVersion(task),
          deletedAt: payload.deletedAt ?? _requireDeletedAt(task),
        ),
      ),
      _ => throw const FormatException('unsupported sync operation type'),
    };
  }

  Future<SyncOperationOutcome> _handleRemoteException(
    SyncOperationRow operation,
    TaskRemoteException error,
  ) {
    if (error.kind == TaskRemoteExceptionKind.conflict) {
      return _markConflict(operation, error);
    }

    if (error.isRetryable) {
      return _markRetryableFailure(operation, error.message);
    }

    return _markPermanentFailure(operation, error.message);
  }

  Future<SyncOperationOutcome> _markRetryableFailure(
    SyncOperationRow operation,
    String message,
  ) async {
    final String safeMessage = _safeMessage(
      message,
      fallback: 'sync request failed',
    );
    final int nextAttempts = operation.attempts + 1;

    if (nextAttempts >= maxAttempts) {
      await syncOperationRepository.recordFailure(
        id: operation.id,
        lastError: safeMessage,
      );
      await taskRepository.markTaskFailed(
        localId: operation.entityLocalId,
        lastError: safeMessage,
      );
      return SyncOperationOutcome.permanentFailure;
    }

    await syncOperationRepository.recordRetryableFailure(
      id: operation.id,
      lastError: safeMessage,
    );
    await taskRepository.markTaskPending(
      localId: operation.entityLocalId,
      lastError: safeMessage,
    );
    return SyncOperationOutcome.retryableFailure;
  }

  Future<SyncOperationOutcome> _markPermanentFailure(
    SyncOperationRow operation,
    String message,
  ) async {
    final String safeMessage = _safeMessage(
      message,
      fallback: 'sync operation failed',
    );

    await syncOperationRepository.recordFailure(
      id: operation.id,
      lastError: safeMessage,
    );
    await taskRepository.markTaskFailed(
      localId: operation.entityLocalId,
      lastError: safeMessage,
    );
    return SyncOperationOutcome.permanentFailure;
  }

  Future<SyncOperationOutcome> _markConflict(
    SyncOperationRow operation,
    TaskRemoteException error,
  ) async {
    final String safeMessage = _safeMessage(
      error.message,
      fallback: 'task has changed on the server',
    );

    await syncOperationRepository.recordFailure(
      id: operation.id,
      lastError: safeMessage,
    );
    await taskRepository.markTaskConflict(
      localId: operation.entityLocalId,
      lastError: safeMessage,
      serverVersion: error.serverTask?.version,
      serverSnapshot: _conflictSnapshotFrom(error.serverTask),
    );
    return SyncOperationOutcome.conflict;
  }

  TaskConflictSnapshot? _conflictSnapshotFrom(RemoteTask? task) {
    if (task == null) {
      return null;
    }

    return TaskConflictSnapshot(
      remoteId: task.id,
      title: task.title,
      description: task.description,
      completed: task.completed,
      version: task.version,
      updatedAt: task.updatedAt,
      deletedAt: task.deletedAt,
    );
  }

  String _requireRemoteId(LocalTaskRow task) {
    final String? remoteId = task.remoteId;
    if (remoteId == null || remoteId.isEmpty) {
      throw const FormatException('remote task id is not available yet');
    }

    return remoteId;
  }

  int _requireVersion(LocalTaskRow task) {
    final int? version = task.version;
    if (version == null || version <= 0) {
      throw const FormatException('remote task version is not available yet');
    }

    return version;
  }

  DateTime _requireDeletedAt(LocalTaskRow task) {
    final DateTime? deletedAt = task.deletedAt;
    if (deletedAt == null) {
      throw const FormatException('delete operation is missing deleted_at');
    }

    return deletedAt;
  }

  String _safeMessage(String? message, {required String fallback}) {
    final String cleaned = (message ?? '').trim();
    if (cleaned.isEmpty) {
      return fallback;
    }
    if (cleaned.length > 240) {
      return '${cleaned.substring(0, 240)}...';
    }

    return cleaned;
  }
}

enum SyncOperationOutcome {
  success,
  retryableFailure,
  permanentFailure,
  conflict;

  bool get blocksRemainingEntityOperations {
    return this != SyncOperationOutcome.success;
  }
}

class SyncRunResult {
  const SyncRunResult({
    this.processed = 0,
    this.succeeded = 0,
    this.retryableFailures = 0,
    this.permanentFailures = 0,
    this.conflicts = 0,
    this.skippedOperations = 0,
    this.skipped = false,
  });

  final int processed;
  final int succeeded;
  final int retryableFailures;
  final int permanentFailures;
  final int conflicts;
  final int skippedOperations;
  final bool skipped;
}

class SyncRunResultBuilder {
  int processed = 0;
  int succeeded = 0;
  int retryableFailures = 0;
  int permanentFailures = 0;
  int conflicts = 0;
  int skippedOperations = 0;

  void record(SyncOperationOutcome outcome) {
    processed++;

    switch (outcome) {
      case SyncOperationOutcome.success:
        succeeded++;
      case SyncOperationOutcome.retryableFailure:
        retryableFailures++;
      case SyncOperationOutcome.permanentFailure:
        permanentFailures++;
      case SyncOperationOutcome.conflict:
        conflicts++;
    }
  }

  SyncRunResult build() {
    return SyncRunResult(
      processed: processed,
      succeeded: succeeded,
      retryableFailures: retryableFailures,
      permanentFailures: permanentFailures,
      conflicts: conflicts,
      skippedOperations: skippedOperations,
    );
  }
}

class _TaskSyncPayload {
  const _TaskSyncPayload({
    required this.localId,
    required this.title,
    required this.description,
    required this.completed,
    required this.updatedAt,
    this.deletedAt,
  });

  factory _TaskSyncPayload.fromOperation(SyncOperationRow operation) {
    final Object? decoded = jsonDecode(operation.payload);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('sync payload must be an object');
    }

    return _TaskSyncPayload(
      localId: _readString(decoded, 'local_id'),
      title: _readString(decoded, 'title'),
      description: _readString(decoded, 'description'),
      completed: _readBool(decoded, 'completed'),
      updatedAt: _readDateTime(decoded, 'updated_at'),
      deletedAt: _readNullableDateTime(decoded, 'deleted_at'),
    );
  }

  final String localId;
  final String title;
  final String description;
  final bool completed;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

String _readString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is String) {
    return value;
  }

  throw FormatException('$key must be a string');
}

bool _readBool(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is bool) {
    return value;
  }

  throw FormatException('$key must be a boolean');
}

DateTime _readDateTime(Map<String, Object?> json, String key) {
  return _parseDateTime(_readString(json, key), key);
}

DateTime? _readNullableDateTime(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return _parseDateTime(value, key);
  }

  throw FormatException('$key must be a string or null');
}

DateTime _parseDateTime(String value, String key) {
  try {
    return DateTime.parse(value).toUtc();
  } on FormatException {
    throw FormatException('$key must be an RFC3339 timestamp');
  }
}
