import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

part 'app_database.g.dart';

const String taskSyncStatusPending = 'pending';
const String taskSyncStatusSyncing = 'syncing';
const String taskSyncStatusSynced = 'synced';
const String taskSyncStatusFailed = 'failed';
const String taskSyncStatusConflict = 'conflict';

const String syncOperationEntityTask = 'task';
const String syncOperationTypeCreate = 'create';
const String syncOperationTypeUpdate = 'update';
const String syncOperationTypeDelete = 'delete';
const String syncOperationStatusPending = 'pending';
const String syncOperationStatusSyncing = 'syncing';
const String syncOperationStatusCompleted = 'completed';
const String syncOperationStatusFailed = 'failed';

@DataClassName('LocalTaskRow')
class LocalTasks extends Table {
  TextColumn get localId => text()();
  TextColumn get remoteId => text().nullable()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().withLength(max: 2000)();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  TextColumn get syncStatus =>
      text().withDefault(const Constant(taskSyncStatusPending))();
  IntColumn get version => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{localId};
}

@DataClassName('SyncOperationRow')
class SyncOperations extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityLocalId => text()();
  TextColumn get operationType => text()();
  TextColumn get payload => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get status =>
      text().withDefault(const Constant(syncOperationStatusPending))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('TaskConflictRow')
class TaskConflicts extends Table {
  TextColumn get taskLocalId => text()();
  TextColumn get remoteId => text()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().withLength(max: 2000)();
  BoolColumn get completed => boolean()();
  IntColumn get version => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get storedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{taskLocalId};
}

@DriftDatabase(
  tables: <Type>[LocalTasks, SyncOperations, TaskConflicts],
  daos: <Type>[TaskDao, SyncOperationDao, TaskConflictDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'pocketsync',
              web: DriftWebOptions(
                sqlite3Wasm: Uri.parse('sqlite3.wasm'),
                driftWorker: Uri.parse('drift_worker.js'),
                onResult: (result) {
                  assert(() {
                    debugPrint(
                      'PocketSync database storage: '
                      '${result.chosenImplementation.name}; '
                      'missing browser features: ${result.missingFeatures}',
                    );
                    return true;
                  }());
                },
              ),
            ),
      );

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) => migrator.createAll(),
    onUpgrade: (Migrator migrator, int from, int to) async {
      if (from < 2) {
        await migrator.createTable(taskConflicts);
      }
    },
  );
}

@DriftAccessor(tables: <Type>[LocalTasks])
class TaskDao extends DatabaseAccessor<AppDatabase> with _$TaskDaoMixin {
  TaskDao(super.db);

  Stream<List<LocalTaskRow>> watchActiveTasks() {
    return (select(localTasks)
          ..where((LocalTasks table) => table.deletedAt.isNull())
          ..orderBy(<OrderingTerm Function(LocalTasks)>[
            (LocalTasks table) => OrderingTerm.desc(table.updatedAt),
            (LocalTasks table) => OrderingTerm.asc(table.localId),
          ]))
        .watch();
  }

  Future<List<LocalTaskRow>> getActiveTasks() {
    return (select(localTasks)
          ..where((LocalTasks table) => table.deletedAt.isNull())
          ..orderBy(<OrderingTerm Function(LocalTasks)>[
            (LocalTasks table) => OrderingTerm.desc(table.updatedAt),
            (LocalTasks table) => OrderingTerm.asc(table.localId),
          ]))
        .get();
  }

  Future<LocalTaskRow?> getByLocalId(String localId) {
    return (select(localTasks)
          ..where((LocalTasks table) => table.localId.equals(localId)))
        .getSingleOrNull();
  }

  Future<void> upsertTask(LocalTasksCompanion task) {
    return into(localTasks).insertOnConflictUpdate(task);
  }

  Future<void> updateTask(LocalTasksCompanion task) {
    return update(localTasks).replace(task);
  }
}

@DriftAccessor(tables: <Type>[TaskConflicts])
class TaskConflictDao extends DatabaseAccessor<AppDatabase>
    with _$TaskConflictDaoMixin {
  TaskConflictDao(super.db);

  Future<TaskConflictRow?> getByTaskLocalId(String taskLocalId) {
    return (select(taskConflicts)..where(
          (TaskConflicts table) => table.taskLocalId.equals(taskLocalId),
        ))
        .getSingleOrNull();
  }

  Future<void> upsertConflict(TaskConflictsCompanion conflict) {
    return into(taskConflicts).insertOnConflictUpdate(conflict);
  }

  Future<void> deleteByTaskLocalId(String taskLocalId) {
    return (delete(taskConflicts)..where(
          (TaskConflicts table) => table.taskLocalId.equals(taskLocalId),
        ))
        .go();
  }
}

@DriftAccessor(tables: <Type>[SyncOperations])
class SyncOperationDao extends DatabaseAccessor<AppDatabase>
    with _$SyncOperationDaoMixin {
  SyncOperationDao(super.db);

  Stream<List<SyncOperationRow>> watchPendingOperations() {
    return (select(syncOperations)
          ..where(
            (SyncOperations table) =>
                table.status.equals(syncOperationStatusPending),
          )
          ..orderBy(<OrderingTerm Function(SyncOperations)>[
            (SyncOperations table) => OrderingTerm.asc(table.createdAt),
            (SyncOperations table) => OrderingTerm.asc(table.id),
          ]))
        .watch();
  }

  Future<List<SyncOperationRow>> getPendingOperations() {
    return (select(syncOperations)
          ..where(
            (SyncOperations table) =>
                table.status.equals(syncOperationStatusPending),
          )
          ..orderBy(<OrderingTerm Function(SyncOperations)>[
            (SyncOperations table) => OrderingTerm.asc(table.createdAt),
            (SyncOperations table) => OrderingTerm.asc(table.id),
          ]))
        .get();
  }

  Future<bool> hasActiveCreateOperation(String localId) async {
    final SyncOperationRow? operation =
        await (select(syncOperations)
              ..where(
                (SyncOperations table) =>
                    table.entityLocalId.equals(localId) &
                    table.operationType.equals(syncOperationTypeCreate) &
                    table.status.isNotValue(syncOperationStatusCompleted) &
                    table.status.isNotValue(syncOperationStatusFailed),
              )
              ..limit(1))
            .getSingleOrNull();

    return operation != null;
  }

  Future<void> enqueue(SyncOperationsCompanion operation) {
    return into(syncOperations).insert(operation);
  }

  Future<void> markStatus({
    required String id,
    required String status,
    required DateTime updatedAt,
    String? lastError,
  }) {
    return (update(
      syncOperations,
    )..where((SyncOperations table) => table.id.equals(id))).write(
      SyncOperationsCompanion(
        status: Value<String>(status),
        lastError: Value<String?>(lastError),
        updatedAt: Value<DateTime>(updatedAt),
      ),
    );
  }

  Future<void> recordFailure({
    required String id,
    required DateTime updatedAt,
    required String lastError,
  }) {
    return customUpdate(
      '''
      UPDATE sync_operations
      SET attempts = attempts + 1,
          status = ?,
          last_error = ?,
          updated_at = ?
      WHERE id = ?
      ''',
      variables: <Variable<Object>>[
        Variable<String>(syncOperationStatusFailed),
        Variable<String>(lastError),
        Variable<DateTime>(updatedAt),
        Variable<String>(id),
      ],
      updates: <TableInfo<Table, Object?>>{syncOperations},
    );
  }

  Future<void> recordRetryableFailure({
    required String id,
    required DateTime updatedAt,
    required String lastError,
  }) {
    return customUpdate(
      '''
      UPDATE sync_operations
      SET attempts = attempts + 1,
          status = ?,
          last_error = ?,
          updated_at = ?
      WHERE id = ?
      ''',
      variables: <Variable<Object>>[
        Variable<String>(syncOperationStatusPending),
        Variable<String>(lastError),
        Variable<DateTime>(updatedAt),
        Variable<String>(id),
      ],
      updates: <TableInfo<Table, Object?>>{syncOperations},
    );
  }
}
