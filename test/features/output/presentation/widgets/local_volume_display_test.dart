import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/features/dlna/domain/dlna_state.dart';
import 'package:songloft_flutter/features/dlna/presentation/providers/dlna_provider.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/roon_controls.dart';
import 'package:songloft_flutter/features/player/domain/player_state.dart';
import 'package:songloft_flutter/features/player/presentation/providers/player_provider.dart';

class _Player extends PlayerNotifier {
  @override
  PlayerState build() =>
      PlayerState.initial.copyWith(volume: 10.589271367982377);
}

class _Outputs extends OutputController {
  @override
  OutputState build() => const OutputState();
}

class _Groups extends OutputController {
  @override
  OutputState build() => const OutputState(
    players: [
      OutputDevice(
        id: 'a',
        name: 'Room A',
        kind: OutputKind.raop,
        online: true,
      ),
      OutputDevice(
        id: 'b',
        name: 'Room B',
        kind: OutputKind.raop,
        online: true,
      ),
    ],
    groups: [
      OutputGroup(
        id: 'g1',
        name: 'Room A',
        members: [OutputMember(playerId: 'a')],
      ),
      OutputGroup(
        id: 'g2',
        name: 'Room B',
        members: [OutputMember(playerId: 'b')],
      ),
    ],
  );
  @override
  Future<void> refresh({bool silent = false}) async {}
  @override
  Future<GroupVolume?> groupVolume(String id) async => const GroupVolume(
    volume: 8,
    members: [GroupVolumeMember(playerId: 'a', volume: 8)],
  );
}

class _Dlna extends DlnaNotifier {
  @override
  DlnaState build() => const DlnaState();
}

void main() {
  testWidgets(
    'Web volume is displayed as an integer and slider uses integer steps',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerStateProvider.overrideWith(_Player.new),
            outputControllerProvider.overrideWith(_Outputs.new),
            dlnaStateProvider.overrideWith(_Dlna.new),
          ],
          child: const MaterialApp(
            home: Scaffold(body: Center(child: RoonVolumeButton())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('11'), findsOneWidget);
      expect(find.textContaining('10.589'), findsNothing);
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.divisions, 100);
    },
  );
  testWidgets('transfer replaces the volume popup rather than stacking on it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'roomtone_zone_focus': 'g1'});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWith(_Player.new),
          outputControllerProvider.overrideWith(_Groups.new),
          dlnaStateProvider.overrideWith(_Dlna.new),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Center(child: RoonVolumeButton())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    await tester.tap(find.byTooltip('转移当前区域的播放'));
    await tester.pumpAndSettle();
    expect(find.text('转换区域'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('转移当前区域的播放'), findsNothing);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
  });
}
