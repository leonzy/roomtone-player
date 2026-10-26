import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/features/output/data/output_api.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/group_volume.dart';

/// 内存版输出 API：模拟服务端 `clamp(base + offset)` 的组音量语义。
class _FakeOutputApi extends OutputApi {
  _FakeOutputApi({required this.players, required this.baseVolume})
    : super(dio: Dio());

  final List<OutputDevice> players;
  int baseVolume;

  /// 这些成员在 setGroupVolume 时返回 ok=false，模拟部分设备下发失败。
  Set<String> failMembers = <String>{};

  final Map<String, int> offsets = <String, int>{};
  final List<int> volumeCalls = <int>[];
  final List<String> updateCalls = <String>[];

  GroupVolume _volume() {
    return GroupVolume(
      volume: baseVolume,
      members:
          players.map((player) {
            final offset = offsets[player.id] ?? 0;
            final failed = failMembers.contains(player.id);
            return GroupVolumeMember(
              playerId: player.id,
              volume: (baseVolume + offset).clamp(0, 100).toInt(),
              volumeOffset: offset,
              ok: !failed,
              error: failed ? 'timeout' : '',
            );
          }).toList(),
    );
  }

  @override
  Future<List<OutputDevice>> listPlayers() async => players;

  @override
  Future<List<OutputGroup>> playback() async => const <OutputGroup>[];

  @override
  Future<GroupVolume> getGroupVolume(String groupId) async => _volume();

  @override
  Future<GroupVolume> setGroupVolume(
    String groupId, {
    required int volume,
    bool muted = false,
  }) async {
    volumeCalls.add(volume);
    baseVolume = volume;
    return _volume();
  }

  @override
  Future<OutputGroup> updateMember(
    String groupId,
    String playerId, {
    int? delayMs,
    int? volumeOffset,
  }) async {
    updateCalls.add('$playerId:$volumeOffset');
    if (volumeOffset != null) offsets[playerId] = volumeOffset;
    return OutputGroup(id: groupId, name: '组', masterId: playerId);
  }
}

OutputDevice _player(String id, String name) => OutputDevice(
  id: id,
  kind: OutputKind.raop,
  name: name,
  online: true,
  volume: 50,
);

Widget _app(_FakeOutputApi api) {
  return ProviderScope(
    overrides: [outputApiProvider.overrideWithValue(api)],
    child: const MaterialApp(
      home: Scaffold(body: GroupVolumeControl(groupId: 'g1')),
    ),
  );
}

Finder _memberRow(String playerId) =>
    find.byKey(ValueKey<String>('group-volume-member-$playerId'));

void main() {
  testWidgets('组滑杆调用 setGroupVolume', (tester) async {
    final api = _FakeOutputApi(
      players: <OutputDevice>[_player('p1', '客厅')],
      baseVolume: 40,
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(
      find.byKey(const Key('group-volume-slider')),
    );
    expect(slider.value, 40);

    slider.onChanged!(72);
    slider.onChangeEnd!(72);
    await tester.pumpAndSettle();

    expect(api.volumeCalls, <int>[72]);
  });

  testWidgets('成员 +10/-10 后值 = clamp(base+offset)', (tester) async {
    final api = _FakeOutputApi(
      players: <OutputDevice>[_player('p1', '客厅')],
      baseVolume: 95,
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('group-volume-plus-p1')),
    );
    await tester.pumpAndSettle();

    expect(api.updateCalls, <String>['p1:10']);
    expect(api.volumeCalls.last, 95);
    // clamp(95 + 10) = 100，不能显示 105。
    expect(
      find.descendant(of: _memberRow('p1'), matching: find.text('100')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('group-volume-minus-p1')),
    );
    await tester.pumpAndSettle();

    expect(api.updateCalls, <String>['p1:10', 'p1:0']);
    expect(
      find.descendant(of: _memberRow('p1'), matching: find.text('95')),
      findsOneWidget,
    );
  });

  testWidgets('部分失败时列出失败成员名', (tester) async {
    final api = _FakeOutputApi(
      players: <OutputDevice>[_player('p1', '客厅'), _player('p2', '卧室')],
      baseVolume: 50,
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    api.failMembers = <String>{'p2'};
    final slider = tester.widget<Slider>(
      find.byKey(const Key('group-volume-slider')),
    );
    slider.onChanged!(60);
    slider.onChangeEnd!(60);
    await tester.pumpAndSettle();

    expect(find.textContaining('1 台设备音量下发失败'), findsOneWidget);
    expect(find.text('卧室：timeout'), findsOneWidget);
    // 已成功的成员不回滚，仍显示新值。
    expect(
      find.descendant(of: _memberRow('p1'), matching: find.text('60')),
      findsOneWidget,
    );
  });
}
