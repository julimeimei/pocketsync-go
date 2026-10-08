import '../../../core/database/app_database.dart';

class SyncOperationLocalRepository {
  const SyncOperationLocalRepository(this._database);

  final AppDatabase _database;

  Stream<List<SyncOperationRow>> watchPendingOperations() {
    return _database.syncOperationDao.watchPendingOperations();
  }

  Future<List<SyncOperationRow>> getPendingOperations() {
    return _database.syncOperationDao.getPendingOperations();
  }

  Future<void> markSyncing(String id, {DateTime? now}) {
    return _database.syncOperationDao.markStatus(
      id: id,
      status: syncOperationStatusSyncing,
      updatedAt: now ?? DateTime.now().toUtc(),
    );
  }

  Future<void> markCompleted(String id, {DateTime? now}) {
    return _database.syncOperationDao.markStatus(
      id: id,
      status: syncOperationStatusCompleted,
      updatedAt: now ?? DateTime.now().toUtc(),
    );
  }

  Future<void> recordFailure({
    required String id,
    required String lastError,
    DateTime? now,
  }) {
    return _database.syncOperationDao.recordFailure(
      id: id,
      updatedAt: now ?? DateTime.now().toUtc(),
      lastError: lastError,
    );
  }

  Future<void> recordRetryableFailure({
    required String id,
    required String lastError,
    DateTime? now,
  }) {
    return _database.syncOperationDao.recordRetryableFailure(
      id: id,
      updatedAt: now ?? DateTime.now().toUtc(),
      lastError: lastError,
    );
  }
}
