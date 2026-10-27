import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/l10n/app_localizations.dart';
import 'package:songloft_flutter/shared/layouts/adaptive_scaffold.dart';

void main() {
  for (final width in [320.0, 446.0, 599.0]) {
    testWidgets('queue is visible and closable at width $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 812);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var open = false;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder:
                (context, setState) => AdaptiveScaffold(
                  body: const Text('Library'),
                  currentIndex: 0,
                  onDestinationSelected: (_) {},
                  destinations: const [
                    NavDestination(
                      label: 'Home',
                      icon: Icon(Icons.home),
                      selectedIcon: Icon(Icons.home),
                    ),
                    NavDestination(
                      label: 'Settings',
                      icon: Icon(Icons.settings),
                      selectedIcon: Icon(Icons.settings),
                    ),
                  ],
                  bottomPlayer: TextButton(
                    onPressed: () => setState(() => open = !open),
                    child: const Text('Queue'),
                  ),
                  playlistDrawer:
                      open
                          ? Material(
                            child: Column(
                              children: [
                                TextButton(
                                  onPressed: () => setState(() => open = false),
                                  child: const Text('Close queue'),
                                ),
                                const Expanded(
                                  child: Center(child: Text('Track 1')),
                                ),
                              ],
                            ),
                          )
                          : null,
                ),
          ),
        ),
      );
      await tester.tap(find.text('Queue'));
      await tester.pumpAndSettle();
      expect(find.text('Track 1').hitTestable(), findsOneWidget);
      expect(
        tester.getRect(find.text('Track 1')).right,
        lessThanOrEqualTo(width),
      );
      expect(find.text('Queue').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Close queue'));
      await tester.pumpAndSettle();
      expect(find.text('Track 1'), findsNothing);
      expect(find.text('Library').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
