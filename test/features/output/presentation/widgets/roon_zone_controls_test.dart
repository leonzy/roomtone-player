import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/features/output/data/output_api.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/presentation/providers/zone_focus_provider.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/roon_volume.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/roon_controls.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/signal_path.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/roon_zone_settings.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/zone_display.dart';
import 'package:songloft_flutter/features/output/presentation/pages/transfer_sheet.dart';
import 'package:songloft_flutter/features/library/presentation/providers/songs_provider.dart';
import 'package:songloft_flutter/shared/models/song.dart';

class _Api extends OutputApi {
  _Api() : super(dio: Dio());
  final names = {'a': '书房', 'b': '卧室', 'c': '客厅'};
  final volumes = {'a': 10, 'b': 2, 'c': 8};
  final offsets = {'a': 0, 'b': -8};
  final muted = <String, bool>{};
  final deviceWrites = <String>[];
  String transferTo = '';
  int base = 10;
  bool split = false;
  String playbackError = '';
  OutputDevice device(String id) => OutputDevice(
    id: id,
    name: names[id]!,
    kind: OutputKind.raop,
    online: true,
    volume: volumes[id]!,
    muted: muted[id] ?? false,
  );
  OutputGroup get source => OutputGroup(
    id: 'g1',
    name: '旧组名',
    masterId: 'a',
    members: [
      const OutputMember(playerId: 'a'),
      if (!split) const OutputMember(playerId: 'b'),
    ],
    status: OutputStatus(
      songId: 1,
      state: playbackError.isEmpty ? PlayState.paused : PlayState.error,
      error: playbackError,
    ),
    signalPath: const SignalPath(
      kind: SignalPathKind.lossless,
      stages: [SignalStage(name: '输出', detail: 'L16')],
    ),
  );
  @override
  Future<List<OutputDevice>> listPlayers() async =>
      names.keys.map(device).toList();
  @override
  Future<List<OutputGroup>> playback() async => [
    source,
    const OutputGroup(
      id: 'g2',
      name: '客厅',
      masterId: 'c',
      members: [OutputMember(playerId: 'c')],
    ),
  ];
  @override
  Future<GroupVolume> getGroupVolume(String id) async =>
      id == 'g2'
          ? GroupVolume(
            volume: 8,
            members: [
              GroupVolumeMember(
                playerId: 'c',
                volume: volumes['c']!,
                volumeOffset: offsets['c'] ?? 0,
              ),
            ],
          )
          : GroupVolume(
            volume: base,
            members:
                ['a', if (!split) 'b']
                    .map(
                      (id) => GroupVolumeMember(
                        playerId: id,
                        volume: volumes[id]!,
                        volumeOffset: offsets[id]!,
                      ),
                    )
                    .toList(),
          );
  @override
  Future<OutputGroup> updateMember(
    String groupId,
    String playerId, {
    int? delayMs,
    int? volumeOffset,
  }) async {
    offsets[playerId] = volumeOffset!;
    return source;
  }

  @override
  Future<OutputDevice> setVolume(
    String id, {
    required int volume,
    bool muted = false,
  }) async {
    deviceWrites.add(id);
    volumes[id] = volume;
    this.muted[id] = muted;
    return device(id);
  }

  @override
  Future<GroupVolume> setGroupVolume(
    String groupId, {
    required int volume,
    bool muted = false,
  }) async {
    base = volume;
    for (final id in ['a', 'b']) {
      volumes[id] = (base + offsets[id]!).clamp(0, 100);
      this.muted[id] = muted;
    }
    return getGroupVolume(groupId);
  }

  @override
  Future<OutputDevice> updatePlayer(
    String id, {
    String? name,
    String? takeover,
  }) async {
    names[id] = name!;
    return device(id);
  }

  @override
  Future<void> transfer({
    required String fromGroupId,
    required String toGroupId,
    String onlyPlayerId = '',
  }) async {
    transferTo = toGroupId;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api,
  Widget child,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        outputApiProvider.overrideWithValue(api),
        songDetailProvider(1).overrideWith(
          (ref) async => Song(
            id: 1,
            type: 'local',
            title: '测试歌曲',
            artist: '演奏者',
            duration: 120,
            addedAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('握手失败显示连接失败，不显示绿色成功链路', (tester) async {
    SharedPreferences.setMockInitialValues({'roomtone_zone_focus': 'g1'});
    final api = _Api()..playbackError = 'raop: OPTIONS 返回 453';
    await _pump(tester, api, const RoonSignalButton());
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.text('信号路径：连接失败'), findsOneWidget);
    expect(find.text('raop: OPTIONS 返回 453'), findsOneWidget);
    expect(find.byType(SignalPathPanel), findsNothing);
  });
  testWidgets('同一区域拆组后移除失效成员音量', (tester) async {
    final api = _Api();
    final container = await _pump(
      tester,
      api,
      const RoonGroupVolumeControl(groupId: 'g1'),
    );
    expect(find.byType(Slider), findsNWidgets(2));
    api.split = true;
    await container
        .read(outputControllerProvider.notifier)
        .refresh(silent: true);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byKey(const ValueKey('speaker-volume-b')), findsNothing);
    expect(api.deviceWrites, isEmpty);
  });
  testWidgets('转移焦点后音量控件清除旧成员与未提交拖动', (tester) async {
    final api = _Api();
    final group = ValueNotifier<String>('g1');
    await _pump(
      tester,
      api,
      ValueListenableBuilder<String>(
        valueListenable: group,
        builder: (_, id, _) => RoonGroupVolumeControl(groupId: id),
      ),
    );
    final oldSlider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('speaker-volume-b')),
        matching: find.byType(Slider),
      ),
    );
    oldSlider.onChanged!(20); // Pending debounce must not survive transfer.
    group.value = 'g2';
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.deviceWrites, isEmpty);
    expect(find.byKey(const ValueKey('speaker-volume-b')), findsNothing);
    final current = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('speaker-volume-c')),
        matching: find.byType(Slider),
      ),
    );
    current.onChangeEnd!(9);
    await tester.pumpAndSettle();
    expect(api.deviceWrites, ['c']);
    expect(api.volumes['b'], 2);
    expect(api.volumes['c'], 9);
    await tester.pumpWidget(const SizedBox.shrink());
    group.dispose();
  });
  testWidgets('编组显示成员名称与短名称', (tester) async {
    final api = _Api();
    final state = OutputState(
      players: await api.listPlayers(),
      groups: await api.playback(),
    );
    final zone = buildZoneEntries(state).firstWhere((z) => z.id == 'g1');
    expect(zone.compactName, '书房 + 1');
    expect(zoneIconFor(zone), Icons.link);
    await tester.pumpWidget(MaterialApp(home: ZoneMemberNames(zone: zone)));
    expect(find.text('书房'), findsOneWidget);
    expect(find.text('卧室'), findsOneWidget);
    expect(find.text('旧组名'), findsNothing);
  });
  testWidgets('成员滑杆只改该音箱，整体调整保留音量差', (tester) async {
    final api = _Api();
    await _pump(tester, api, const RoonGroupVolumeControl(groupId: 'g1'));
    expect(find.byType(Slider), findsNWidgets(2));
    final slider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('speaker-volume-b')),
        matching: find.byType(Slider),
      ),
    );
    slider.onChanged!(7);
    slider.onChangeEnd!(7);
    await tester.pumpAndSettle();
    expect(api.deviceWrites, ['b']);
    expect(api.volumes['a'], 10);
    expect(api.volumes['b'], 7);
    await tester.tap(find.byKey(const Key('group-volume-down')));
    await tester.pumpAndSettle();
    expect(api.volumes['a'], 9);
    expect(api.volumes['b'], 6);
    await tester.tap(find.byKey(const Key('group-mute')));
    await tester.pumpAndSettle();
    expect(api.muted['a'], true);
    expect(api.muted['b'], true);
    expect(find.text('取消全部静音'), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-mute')));
    await tester.pumpAndSettle();
    expect(api.muted['a'], false);
    expect(api.volumes['b'], 6);
  });
  testWidgets('转移显示当前编组、歌曲及目标音箱，完成后聚焦目标', (tester) async {
    final api = _Api();
    final container = await _pump(
      tester,
      api,
      Builder(
        builder:
            (ctx) => TextButton(
              onPressed:
                  () => showDialog<void>(
                    context: ctx,
                    builder: (_) => const TransferZoneDialog(groupId: 'g1'),
                  ),
              child: const Text('打开'),
            ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('转换区域'), findsOneWidget);
    expect(find.text('书房'), findsOneWidget);
    expect(find.text('卧室'), findsOneWidget);
    expect(find.text('测试歌曲'), findsOneWidget);
    expect(find.text('演奏者'), findsOneWidget);
    expect(find.text('客厅'), findsOneWidget);
    expect(find.text('单机播放'), findsNothing);
    expect(find.byKey(const ValueKey('transfer-target-g1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('transfer-target-g2')));
    await tester.pumpAndSettle();
    expect(api.transferTo, 'g2');
    expect(container.read(zoneFocusProvider), 'g2');
    expect(find.byType(TransferZoneDialog), findsNothing);
  });
  testWidgets('音箱设置可修改名称并立即更新', (tester) async {
    final api = _Api();
    await _pump(tester, api, const SpeakerSettingsRow(playerId: 'a'));
    await tester.tap(find.byKey(const ValueKey('rename-speaker-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('speaker-name-field')), '工作室');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.names['a'], '工作室');
    expect(find.text('工作室'), findsOneWidget);
  });
}
