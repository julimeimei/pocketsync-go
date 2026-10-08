import 'package:flutter/material.dart';

import 'router.dart';
import 'theme.dart';

class PocketSyncApp extends StatelessWidget {
  const PocketSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'PocketSync',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      routerConfig: appRouter,
    );
  }
}
