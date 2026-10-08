import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_provider.dart';
import '../../../sync/data/sync_operation_local_repository.dart';
import '../data/task_local_repository.dart';

final Provider<TaskRepository> taskLocalRepositoryProvider =
    Provider<TaskRepository>((ref) {
      return TaskLocalRepository(ref.watch(appDatabaseProvider));
    });

final Provider<SyncOperationLocalRepository>
syncOperationLocalRepositoryProvider = Provider<SyncOperationLocalRepository>((
  ref,
) {
  return SyncOperationLocalRepository(ref.watch(appDatabaseProvider));
});

final StreamProvider<List<LocalTaskRow>> taskListProvider =
    StreamProvider<List<LocalTaskRow>>((ref) {
      return ref.watch(taskLocalRepositoryProvider).watchActiveTasks();
    });

final StreamProvider<int> pendingSyncOperationCountProvider =
    StreamProvider<int>((ref) {
      return ref
          .watch(syncOperationLocalRepositoryProvider)
          .watchPendingOperations()
          .map((List<SyncOperationRow> operations) => operations.length);
    });
