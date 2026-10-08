import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../sync/application/network_status.dart';
import '../../../sync/application/sync_coordinator.dart';
import '../../../sync/application/sync_engine.dart';
import '../data/task_local_repository.dart';
import '../domain/local_task_input.dart';
import 'task_providers.dart';

class TasksHomeScreen extends ConsumerWidget {
  const TasksHomeScreen({super.key});

  static const String routeName = 'tasks';
  static const String routePath = '/';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final AsyncValue<List<LocalTaskRow>> tasks = ref.watch(taskListProvider);
    final AsyncValue<int> pendingCount = ref.watch(
      pendingSyncOperationCountProvider,
    );
    final AsyncValue<NetworkStatus> networkStatus = ref.watch(
      networkStatusProvider,
    );
    final SyncCoordinatorState syncState = ref.watch(syncCoordinatorProvider);
    final bool isOffline = networkStatus.value == NetworkStatus.offline;
    final bool canSync = !syncState.isSyncing && !isOffline;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PocketSync'),
        actions: <Widget>[
          IconButton(
            key: const Key('sync.manual'),
            onPressed: canSync ? () => _syncNow(context, ref) : null,
            tooltip: 'Sync now',
            icon: syncState.isSyncing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: tasks.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, StackTrace stackTrace) {
            return _TaskLoadError(
              onRetry: () => ref.invalidate(taskListProvider),
            );
          },
          data: (List<LocalTaskRow> items) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: <Widget>[
                Text(
                  'Tasks',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                _SyncStatusStrip(
                  pendingCount: pendingCount,
                  networkStatus: networkStatus,
                  syncState: syncState,
                ),
                const SizedBox(height: 16),
                if (items.isEmpty)
                  _EmptyTasksView(onCreate: () => _openTaskEditor(context, ref))
                else
                  for (final LocalTaskRow task in items) ...<Widget>[
                    _TaskCard(
                      task: task,
                      onToggle: () => _toggleCompleted(context, ref, task),
                      onEdit: () => _openTaskEditor(context, ref, task: task),
                      onDelete: () => _confirmDelete(context, ref, task),
                      onResolveConflict: () =>
                          _openConflictResolver(context, ref, task),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('task.add'),
        onPressed: () => _openTaskEditor(context, ref),
        tooltip: 'Create task',
        child: const Icon(Icons.add_rounded),
      ),
    );
  }

  Future<void> _openTaskEditor(
    BuildContext context,
    WidgetRef ref, {
    LocalTaskRow? task,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) => _TaskEditorSheet(task: task),
    );
  }

  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final NetworkStatus? status = ref.read(networkStatusProvider).value;
    if (status == NetworkStatus.offline) {
      _showSafeSnackBar(context, 'You are offline');
      return;
    }

    final SyncRunResult? result = await ref
        .read(syncCoordinatorProvider.notifier)
        .sync();

    if (!context.mounted) {
      return;
    }

    final SyncCoordinatorState state = ref.read(syncCoordinatorProvider);
    _showSafeSnackBar(
      context,
      _manualSyncMessage(result: result, state: state),
    );
  }

  Future<void> _toggleCompleted(
    BuildContext context,
    WidgetRef ref,
    LocalTaskRow task,
  ) async {
    try {
      await ref
          .read(taskLocalRepositoryProvider)
          .updateTask(
            localId: task.localId,
            input: LocalTaskInput(
              title: task.title,
              description: task.description,
              completed: !task.completed,
            ),
          );
    } on Object {
      if (context.mounted) {
        _showSafeSnackBar(context, 'Could not update task');
      }
    }
  }

  Future<void> _openConflictResolver(
    BuildContext context,
    WidgetRef ref,
    LocalTaskRow task,
  ) async {
    final TaskRepository repository = ref.read(taskLocalRepositoryProvider);
    final TaskConflictSnapshot? conflict = await repository.getConflictForTask(
      task.localId,
    );

    if (!context.mounted) {
      return;
    }
    if (conflict == null) {
      _showSafeSnackBar(context, 'Conflict details are not available');
      return;
    }

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) {
        return _ConflictResolutionSheet(task: task, conflict: conflict);
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    LocalTaskRow task,
  ) async {
    final bool? shouldDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete task'),
          content: Text(
            task.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: const Key('task.confirmDelete'),
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    try {
      await ref
          .read(taskLocalRepositoryProvider)
          .softDeleteTask(localId: task.localId);
    } on Object {
      if (context.mounted) {
        _showSafeSnackBar(context, 'Could not delete task');
      }
    }
  }
}

class _SyncStatusStrip extends StatelessWidget {
  const _SyncStatusStrip({
    required this.pendingCount,
    required this.networkStatus,
    required this.syncState,
  });

  final AsyncValue<int> pendingCount;
  final AsyncValue<NetworkStatus> networkStatus;
  final SyncCoordinatorState syncState;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String countLabel = pendingCount.when(
      data: (int count) => '$count pending',
      error: (Object error, StackTrace stackTrace) => 'Unavailable',
      loading: () => 'Checking',
    );
    final _NetworkStatusStyle networkStyle = _networkStyleFor(
      networkStatus,
      syncState,
      colors,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: networkStyle.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            syncState.isSyncing
                ? SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: networkStyle.foreground,
                    ),
                  )
                : Icon(networkStyle.icon, color: networkStyle.foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    networkStyle.label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: networkStyle.foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    countLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: networkStyle.foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  _NetworkStatusStyle _networkStyleFor(
    AsyncValue<NetworkStatus> networkStatus,
    SyncCoordinatorState syncState,
    ColorScheme colors,
  ) {
    if (syncState.isSyncing) {
      return _NetworkStatusStyle(
        icon: Icons.sync_rounded,
        label: 'Syncing',
        foreground: colors.onTertiaryContainer,
        background: colors.tertiaryContainer,
      );
    }

    return networkStatus.when(
      data: (NetworkStatus status) {
        return switch (status) {
          NetworkStatus.online => _NetworkStatusStyle(
            icon: Icons.cloud_done_rounded,
            label: 'Online',
            foreground: colors.onPrimaryContainer,
            background: colors.primaryContainer,
          ),
          NetworkStatus.offline => _NetworkStatusStyle(
            icon: Icons.wifi_off_rounded,
            label: 'Offline',
            foreground: colors.onSecondaryContainer,
            background: colors.secondaryContainer,
          ),
        };
      },
      error: (Object error, StackTrace stackTrace) => _NetworkStatusStyle(
        icon: Icons.cloud_off_rounded,
        label: 'Network unknown',
        foreground: colors.onErrorContainer,
        background: colors.errorContainer,
      ),
      loading: () => _NetworkStatusStyle(
        icon: Icons.cloud_sync_rounded,
        label: 'Checking network',
        foreground: colors.onSecondaryContainer,
        background: colors.secondaryContainer,
      ),
    );
  }
}

class _NetworkStatusStyle {
  const _NetworkStatusStyle({
    required this.icon,
    required this.label,
    required this.foreground,
    required this.background,
  });

  final IconData icon;
  final String label;
  final Color foreground;
  final Color background;
}

class _EmptyTasksView extends StatelessWidget {
  const _EmptyTasksView({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Column(
          children: <Widget>[
            Icon(Icons.task_alt_rounded, size: 40, color: colors.primary),
            const SizedBox(height: 12),
            Text(
              'No tasks yet',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New task'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskLoadError extends StatelessWidget {
  const _TaskLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline_rounded, size: 40, color: colors.error),
            const SizedBox(height: 12),
            Text(
              'Could not load tasks',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onResolveConflict,
  });

  final LocalTaskRow task;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onResolveConflict;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Checkbox(
              key: Key('task.checkbox.${task.localId}'),
              value: task.completed,
              onChanged: (_) => onToggle(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onSurface,
                        decoration: task.completed
                            ? TextDecoration.lineThrough
                            : null,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (task.description.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        task.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        _TaskSyncStatusChip(status: task.syncStatus),
                        if (task.syncStatus == taskSyncStatusConflict)
                          OutlinedButton.icon(
                            key: Key('task.resolve.${task.localId}'),
                            onPressed: onResolveConflict,
                            icon: const Icon(Icons.compare_arrows_rounded),
                            label: const Text('Resolve'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  key: Key('task.edit.${task.localId}'),
                  onPressed: onEdit,
                  tooltip: 'Edit task',
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: Key('task.delete.${task.localId}'),
                  onPressed: onDelete,
                  tooltip: 'Delete task',
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskSyncStatusChip extends StatelessWidget {
  const _TaskSyncStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final _SyncStatusStyle style = _styleForStatus(status, colors);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(style.icon, size: 16, color: style.foreground),
            const SizedBox(width: 6),
            Text(
              style.label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: style.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  _SyncStatusStyle _styleForStatus(String status, ColorScheme colors) {
    return switch (status) {
      taskSyncStatusSyncing => _SyncStatusStyle(
        icon: Icons.sync_rounded,
        label: 'syncing',
        foreground: colors.onTertiaryContainer,
        background: colors.tertiaryContainer,
      ),
      taskSyncStatusSynced => _SyncStatusStyle(
        icon: Icons.cloud_done_rounded,
        label: 'synced',
        foreground: colors.onPrimaryContainer,
        background: colors.primaryContainer,
      ),
      taskSyncStatusFailed => _SyncStatusStyle(
        icon: Icons.error_outline_rounded,
        label: 'failed',
        foreground: colors.onErrorContainer,
        background: colors.errorContainer,
      ),
      taskSyncStatusConflict => _SyncStatusStyle(
        icon: Icons.warning_amber_rounded,
        label: 'conflict',
        foreground: colors.onErrorContainer,
        background: colors.errorContainer,
      ),
      _ => _SyncStatusStyle(
        icon: Icons.schedule_rounded,
        label: 'pending',
        foreground: colors.onSecondaryContainer,
        background: colors.secondaryContainer,
      ),
    };
  }
}

class _SyncStatusStyle {
  const _SyncStatusStyle({
    required this.icon,
    required this.label,
    required this.foreground,
    required this.background,
  });

  final IconData icon;
  final String label;
  final Color foreground;
  final Color background;
}

class _ConflictResolutionSheet extends ConsumerStatefulWidget {
  const _ConflictResolutionSheet({required this.task, required this.conflict});

  final LocalTaskRow task;
  final TaskConflictSnapshot conflict;

  @override
  ConsumerState<_ConflictResolutionSheet> createState() =>
      _ConflictResolutionSheetState();
}

class _ConflictResolutionSheetState
    extends ConsumerState<_ConflictResolutionSheet> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final EdgeInsets viewInsets = MediaQuery.viewInsetsOf(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Resolve conflict',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          _ConflictVersionComparison(
            localTask: widget.task,
            serverTask: widget.conflict,
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              OutlinedButton.icon(
                key: const Key('conflict.keepLocal'),
                onPressed: _saving
                    ? null
                    : () => _resolve(ConflictResolutionChoice.keepLocal),
                icon: const Icon(Icons.upload_rounded),
                label: const Text('Keep local'),
              ),
              FilledButton.icon(
                key: const Key('conflict.useServer'),
                onPressed: _saving
                    ? null
                    : () => _resolve(ConflictResolutionChoice.useServer),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Use server'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(ConflictResolutionChoice choice) async {
    setState(() => _saving = true);

    try {
      final TaskRepository repository = ref.read(taskLocalRepositoryProvider);
      switch (choice) {
        case ConflictResolutionChoice.keepLocal:
          await repository.resolveConflictKeepingLocal(
            localId: widget.task.localId,
          );
        case ConflictResolutionChoice.useServer:
          await repository.resolveConflictUsingServer(
            localId: widget.task.localId,
          );
      }

      if (mounted) {
        Navigator.of(context).pop();
        _showSafeSnackBar(
          context,
          choice == ConflictResolutionChoice.keepLocal
              ? 'Local changes queued'
              : 'Server version applied',
        );
      }
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
        _showSafeSnackBar(context, 'Could not resolve conflict');
      }
    }
  }
}

enum ConflictResolutionChoice { keepLocal, useServer }

class _ConflictVersionComparison extends StatelessWidget {
  const _ConflictVersionComparison({
    required this.localTask,
    required this.serverTask,
  });

  final LocalTaskRow localTask;
  final TaskConflictSnapshot serverTask;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      children: <Widget>[
        _ConflictVersionPanel(
          title: 'Local',
          taskTitle: localTask.title,
          description: localTask.description,
          completed: localTask.completed,
          versionLabel: localTask.version?.toString() ?? 'none',
          updatedAt: localTask.updatedAt,
        ),
        const SizedBox(height: 12),
        Icon(
          Icons.swap_vert_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        _ConflictVersionPanel(
          title: 'Server',
          taskTitle: serverTask.title,
          description: serverTask.description,
          completed: serverTask.completed,
          versionLabel: serverTask.version.toString(),
          updatedAt: serverTask.updatedAt,
        ),
      ],
    );
  }
}

class _ConflictVersionPanel extends StatelessWidget {
  const _ConflictVersionPanel({
    required this.title,
    required this.taskTitle,
    required this.description,
    required this.completed,
    required this.versionLabel,
    required this.updatedAt,
  });

  final String title;
  final String taskTitle;
  final String description;
  final bool completed;
  final String versionLabel;
  final DateTime updatedAt;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  'v$versionLabel',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              taskTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (description.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _ConflictMetaChip(
                  icon: completed
                      ? Icons.check_circle_outline_rounded
                      : Icons.radio_button_unchecked_rounded,
                  label: completed ? 'completed' : 'open',
                ),
                _ConflictMetaChip(
                  icon: Icons.schedule_rounded,
                  label: _formatLocalTimestamp(updatedAt),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConflictMetaChip extends StatelessWidget {
  const _ConflictMetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: colors.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskEditorSheet extends ConsumerStatefulWidget {
  const _TaskEditorSheet({this.task});

  final LocalTaskRow? task;

  @override
  ConsumerState<_TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends ConsumerState<_TaskEditorSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late bool _completed;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final LocalTaskRow? task = widget.task;
    _titleController = TextEditingController(text: task?.title ?? '');
    _descriptionController = TextEditingController(
      text: task?.description ?? '',
    );
    _completed = task?.completed ?? false;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final EdgeInsets viewInsets = MediaQuery.viewInsetsOf(context);
    final bool isEditing = widget.task != null;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + viewInsets.bottom),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                isEditing ? 'Edit task' : 'New task',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('task.titleField'),
                controller: _titleController,
                autofocus: true,
                maxLength: 200,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: _validateTitle,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('task.descriptionField'),
                controller: _descriptionController,
                maxLength: 2000,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Description'),
                validator: _validateDescription,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _completed,
                onChanged: _saving
                    ? null
                    : (bool? value) {
                        setState(() => _completed = value ?? false);
                      },
                contentPadding: EdgeInsets.zero,
                title: const Text('Completed'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const Key('task.save'),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(isEditing ? 'Save' : 'Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _validateTitle(String? value) {
    final String cleaned = value?.trim() ?? '';
    if (cleaned.isEmpty) {
      return 'Title is required';
    }
    if (cleaned.length > 200) {
      return 'Title must be at most 200 characters';
    }

    return null;
  }

  String? _validateDescription(String? value) {
    if ((value ?? '').length > 2000) {
      return 'Description must be at most 2000 characters';
    }

    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _saving = true);

    try {
      final LocalTaskInput input = LocalTaskInput(
        title: _titleController.text,
        description: _descriptionController.text,
        completed: _completed,
      );
      final LocalTaskRow? task = widget.task;
      final repository = ref.read(taskLocalRepositoryProvider);

      if (task == null) {
        await repository.createTask(input);
      } else {
        await repository.updateTask(localId: task.localId, input: input);
      }

      if (mounted) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
        _showSafeSnackBar(context, 'Could not save task');
      }
    }
  }
}

void _showSafeSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

String _manualSyncMessage({
  required SyncRunResult? result,
  required SyncCoordinatorState state,
}) {
  if (state.lastError != null) {
    return state.lastError!;
  }
  if (result == null || result.skipped) {
    return 'Sync already running';
  }
  if (result.conflicts > 0) {
    return 'Sync found conflicts';
  }
  if (result.permanentFailures > 0) {
    return 'Sync finished with failures';
  }
  if (result.retryableFailures > 0) {
    return 'Sync will retry later';
  }
  if (result.processed == 0) {
    return 'No pending changes';
  }

  return 'Sync complete';
}

String _formatLocalTimestamp(DateTime value) {
  return value.toLocal().toString().split('.').first;
}
