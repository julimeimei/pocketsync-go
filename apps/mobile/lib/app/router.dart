import 'package:go_router/go_router.dart';

import '../features/tasks/presentation/tasks_home_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: TasksHomeScreen.routePath,
  routes: <RouteBase>[
    GoRoute(
      path: TasksHomeScreen.routePath,
      name: TasksHomeScreen.routeName,
      builder: (context, state) => const TasksHomeScreen(),
    ),
  ],
);
