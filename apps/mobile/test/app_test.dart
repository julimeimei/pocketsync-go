import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketsync_mobile/app/app.dart';
import 'package:pocketsync_mobile/core/database/app_database.dart';
import 'package:pocketsync_mobile/features/tasks/presentation/task_providers.dart';
import 'package:pocketsync_mobile/sync/application/network_status.dart';

void main() {
  testWidgets('renders the PocketSync task shell', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskListProvider.overrideWith(
            (ref) => Stream.value(<LocalTaskRow>[]),
          ),
          pendingSyncOperationCountProvider.overrideWith(
            (ref) => Stream.value(0),
          ),
          networkStatusProvider.overrideWith(
            (ref) => Stream.value(NetworkStatus.online),
          ),
        ],
        child: const PocketSyncApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('PocketSync'), findsOneWidget);
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
    expect(find.byKey(const Key('task.add')), findsOneWidget);
    expect(find.text('No tasks yet'), findsOneWidget);
  });
}
