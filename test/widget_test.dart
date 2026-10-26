import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:songloft_flutter/core/router/app_router.dart';
import 'package:songloft_flutter/main.dart';
import 'package:songloft_flutter/features/playback/presentation/providers/playback_socket_provider.dart';

void main() {
  testWidgets('Songloft app smoke test', (WidgetTester tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder:
              (context, state) => const Scaffold(
                body: Center(child: Text('Songloft app test')),
              ),
        ),
      ],
    );
    addTearDown(router.dispose);

    // Build our app and trigger a frame.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          routerProvider.overrideWithValue(router),
          // 不启动真实 WS / 心跳，否则测试结束时有 pending timer。
          playbackBackgroundEnabledProvider.overrideWithValue(false),
        ],
        child: const SongloftApp(),
      ),
    );

    // Verify that our app shell can render with the test router.
    expect(find.text('Songloft app test'), findsOneWidget);
  });
}
