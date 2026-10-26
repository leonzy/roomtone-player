import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/core/router/app_router.dart';
import 'package:songloft_flutter/core/storage/app_preferences.dart';
import 'package:songloft_flutter/core/theme/app_theme.dart';
import 'package:songloft_flutter/core/theme/built_in_palette.dart';
import 'package:songloft_flutter/core/utils/color_extraction.dart';
import 'package:songloft_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:songloft_flutter/features/settings/data/theme_pack_api.dart';
import 'package:songloft_flutter/features/settings/presentation/providers/built_in_palette_provider.dart';
import 'package:songloft_flutter/features/settings/presentation/providers/theme_pack_provider.dart';
import 'package:songloft_flutter/features/settings/presentation/widgets/built_in_palette_selector.dart';
import 'package:songloft_flutter/features/player/presentation/widgets/player_backdrop.dart';
import 'package:songloft_flutter/main.dart';
import 'package:songloft_flutter/features/playback/presentation/providers/playback_socket_provider.dart';

class _ThemePack extends ActiveThemePackNotifier {
  @override
  Future<ThemePack?> build() async => null;

  void usePack(ThemePack? pack) => state = AsyncData(pack);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'default, unknown saved choice, initialization race and restart',
    () async {
      SharedPreferences.setMockInitialValues({'built_in_palette': 'unknown'});
      final pending = Completer<AppPreferences>();
      final container = ProviderContainer(
        overrides: [
          appPreferencesProvider.overrideWith((ref) => pending.future),
        ],
      );
      addTearDown(container.dispose);
      final initial = container.read(builtInPaletteProvider.future);
      final notifier = container.read(builtInPaletteProvider.notifier);
      final writes = [
        notifier.setPalette(BuiltInPalette.rose),
        notifier.setPalette(BuiltInPalette.forest),
      ];
      pending.complete(await AppPreferences.create());
      expect(await initial, BuiltInPalette.blue);
      await Future.wait(writes);
      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      expect(
        await restored.read(builtInPaletteProvider.future),
        BuiltInPalette.forest,
      );
    },
  );

  test(
    'all palettes provide distinct schemes and readable player text in both modes',
    () {
      for (final dark in [false, true]) {
        final primaryColors = <Color>{};
        for (final palette in BuiltInPalette.values) {
          final theme =
              dark
                  ? AppTheme.darkTheme(seedColor: palette.seedColor)
                  : AppTheme.lightTheme(seedColor: palette.seedColor);
          primaryColors.add(theme.colorScheme.primary);
          for (final cover in [
            Colors.black,
            Colors.white,
            Colors.red,
            Colors.blue,
            Colors.green,
          ]) {
            final highContrast =
                dark
                    ? AppTheme.darkTheme(
                      seedColor: palette.seedColor,
                      increaseContrast: true,
                    )
                    : AppTheme.lightTheme(
                      seedColor: palette.seedColor,
                      increaseContrast: true,
                    );
            final plain = PlayerBackdropColors.fromTheme(
              highContrast,
              CoverPalette(dominantColor: cover, onImageColor: Colors.white),
            );
            expect(plain.background.toSet(), {
              highContrast.colorScheme.surface,
            });
            final tinted = PlayerBackdropColors.fromTheme(
              theme,
              CoverPalette(dominantColor: cover, onImageColor: Colors.white),
            );
            for (var step = 0; step <= 20; step++) {
              final bg =
                  Color.lerp(
                    tinted.background.first,
                    tinted.background.last,
                    step / 20,
                  )!;
              final active = [
                tinted.active.computeLuminance(),
                bg.computeLuminance(),
              ]..sort();
              final secondary = [
                tinted.secondary.computeLuminance(),
                bg.computeLuminance(),
              ]..sort();
              expect(
                (active.last + .05) / (active.first + .05),
                greaterThanOrEqualTo(7),
              );
              expect(
                (secondary.last + .05) / (secondary.first + .05),
                greaterThanOrEqualTo(4.5),
              );
            }
          }
          final player = PlayerBackdropColors.fromTheme(theme);
          for (final bg in player.background) {
            final l = [player.active.computeLuminance(), bg.computeLuminance()]
              ..sort();
            expect((l.last + .05) / (l.first + .05), greaterThanOrEqualTo(7));
          }
        }
        expect(primaryColors, hasLength(BuiltInPalette.values.length));
      }
    },
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'actual app changes palette, theme pack takes precedence ($width)',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Color? primary;
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) {
                primary = Theme.of(context).colorScheme.primary;
                return const Scaffold(body: BuiltInPaletteSelector());
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        final container = ProviderContainer(
          overrides: [
            routerProvider.overrideWithValue(router),
            activeThemePackProvider.overrideWith(_ThemePack.new),
            // 不启动真实 WS / 心跳，否则测试结束时有 pending timer。
            playbackBackgroundEnabledProvider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const SongloftApp(),
          ),
        );
        await tester.pumpAndSettle();
        final before = primary;
        final chips = find.byType(ChoiceChip);
        expect(chips, findsNWidgets(6));
        await tester.tap(chips.at(3));
        await tester.pumpAndSettle();
        expect(primary, isNot(before));
        expect(
          container.read(builtInPaletteProvider).requireValue,
          BuiltInPalette.rose,
        );
        expect(
          (await AppPreferences.create()).getBuiltInPalette(),
          BuiltInPalette.rose,
        );
        final pack = ThemePack.fromJson({
          'theme_id': 'custom',
          'name': 'Custom',
          'data': {
            'light': {'seedColor': '#006A6A'},
            'dark': {'seedColor': '#006A6A'},
          },
        });
        (container.read(activeThemePackProvider.notifier) as _ThemePack)
            .usePack(pack);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(chips.first).onSelected, isNull);
        expect(
          primary,
          AppTheme.lightTheme(themePack: pack).colorScheme.primary,
        );
        (container.read(activeThemePackProvider.notifier) as _ThemePack)
            .usePack(null);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(chips.at(3)).selected, isTrue);
        expect(
          primary,
          AppTheme.lightTheme(
            seedColor: BuiltInPalette.rose.seedColor,
          ).colorScheme.primary,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
