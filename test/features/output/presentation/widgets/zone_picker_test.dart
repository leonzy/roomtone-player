import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/features/output/data/output_api.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/presentation/providers/zone_focus_provider.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/zone_display.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/zone_picker.dart';
import 'package:songloft_flutter/features/playback/domain/playback_event.dart';
import 'package:songloft_flutter/features/playback/presentation/providers/playback_socket_provider.dart';

class _FakeOutputApi extends OutputApi {
  _FakeOutputApi({required this.groups, required this.players})
    : super(dio: Dio());

  List<OutputGroup> groups;
  List<OutputDevice> players;

  final List<String> transportCalls = <String>[];
  final List<String> volumeCalls = <String>[];
  final List<String> transferCalls = <String>[];
  int playbackCalls = 0;

  /// 非空时 transfer 会挂起，用于观察转移中的 UI 状态。
  Completer<void>? transferGate;

  @override
  Future<void> transfer({
    required String fromGroupId,
    required String toGroupId,
    String? onlyPlayerId,
  }) async {
    transferCalls.add('$fromGroupId->$toGroupId');
    final gate = transferGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<List<OutputDevice>> listPlayers() async => players;

  @override
  Future<List<OutputGroup>> playback() async {
    playbackCalls++;
    return groups;
  }

  @override
  Future<OutputStatus> transport(
    String groupId, {
    required String action,
    double? position,
    String? repeat,
    bool? shuffle,
  }) async {
    transportCalls.add('$groupId:$action');
    return groups.firstWhere((group) => group.id == groupId).status;
  }

  @override
  Future<GroupVolume> setGroupVolume(
    String groupId, {
    required int volume,
    bool muted = false,
  }) async {
    volumeCalls.add('$groupId:$volume');
    return GroupVolume(volume: volume, muted: muted);
  }
}

OutputDevice _player(String id, String name, {int volume = 50}) {
  return OutputDevice(
    id: id,
    kind: OutputKind.raop,
    name: name,
    online: true,
    volume: volume,
  );
}

OutputGroup _group({
  required String id,
  required String name,
  required String playerId,
  String state = PlayState.idle,
  int songId = 0,
  String icon = '',
  SignalPath? signalPath,
}) {
  return OutputGroup(
    id: id,
    name: name,
    icon: icon,
    masterId: playerId,
    members: <OutputMember>[OutputMember(playerId: playerId)],
    memberCaps: <MemberCaps>[
      MemberCaps(playerId: playerId, kind: OutputKind.raop, online: true),
    ],
    status: OutputStatus(state: state, songId: songId),
    signalPath: signalPath,
  );
}

SignalPath _signalPath() => const SignalPath(
  kind: SignalPathKind.enhanced,
  stages: <SignalStage>[
    SignalStage(name: '源', detail: 'FLAC 44.1kHz'),
    SignalStage(name: '解码', detail: 'ffmpeg'),
    SignalStage(name: 'DSP', detail: 'EQ: rock'),
    SignalStage(name: '输出', detail: 'L16 44.1kHz/16bit'),
    SignalStage(name: '设备', detail: '客厅 Soundbar'),
  ],
);

Widget _app(_FakeOutputApi api, {Stream<PlaybackEvent>? events}) {
  return ProviderScope(
    overrides: [
      outputApiProvider.overrideWithValue(api),
      // 默认给空流：否则 zoneTransferProvider 会去建真实 WS 连接。
      playbackEventsProvider.overrideWith(
        (ref) => events ?? const Stream<PlaybackEvent>.empty(),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: ZonePickerSheet())),
  );
}

PlaybackEvent _stateEvent(int seq, String groupId) {
  return PlaybackEvent.fromJson(<String, dynamic>{
    'seq': seq,
    'type': 'state',
    'time_ms': seq,
    'group_id': groupId,
    'status': 'playing',
  });
}

ProviderContainer _containerOf(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(ZonePickerSheet)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('点击区域行只切焦点，不发 transport / volume 请求', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[
        _group(id: 'g1', name: '客厅', playerId: 'p1'),
        _group(id: 'g2', name: '卧室', playerId: 'p2'),
      ],
      players: <OutputDevice>[
        _player('p1', '客厅 Soundbar'),
        _player('p2', '卧室 HomePod'),
      ],
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    api.transportCalls.clear();
    api.volumeCalls.clear();
    final playbackCallsBefore = api.playbackCalls;

    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();

    expect(api.transportCalls, isEmpty);
    expect(api.volumeCalls, isEmpty);
    // 切焦点连 GET /playback 都不发，服务端所有区域 status 自然不变。
    expect(api.playbackCalls, playbackCallsBefore);
    expect(_containerOf(tester).read(zoneFocusProvider), 'g1');
  });

  testWidgets('区域行没有播放按钮：点行只切焦点，不发 transport', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[
        _group(id: 'g1', name: '客厅', playerId: 'p1'),
        _group(id: 'g2', name: '卧室', playerId: 'p2'),
      ],
      players: <OutputDevice>[
        _player('p1', '客厅 Soundbar'),
        _player('p2', '卧室 HomePod'),
      ],
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    api.transportCalls.clear();

    // Roon 语义：区域面板只负责选区域，播放交给主播放器。
    expect(
      find.byKey(const ValueKey<String>('zone-transport-g1')),
      findsNothing,
    );

    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();

    expect(api.transportCalls, isEmpty);
    expect(_containerOf(tester).read(zoneFocusProvider), 'g1');
  });

  testWidgets('区域行不显示音量与播放状态：这些只在主播放面板', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[_group(id: 'g1', name: '客厅', playerId: 'p1')],
      players: <OutputDevice>[_player('p1', '客厅 Soundbar')],
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    // Roon 语义：区域弹层只做选择，音量 / 播放状态 / 进度都在播放面板。
    expect(find.byKey(const ValueKey<String>('zone-volume-g1')), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(ZoneStatusLine), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
  });

  testWidgets('有 signal_path 时显示指示点，点开显示五段链路', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[
        _group(id: 'g1', name: '客厅', playerId: 'p1', signalPath: _signalPath()),
      ],
      players: <OutputDevice>[_player('p1', '客厅 Soundbar')],
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    final dot = find.byKey(const ValueKey<String>('zone-signal-g1'));
    expect(dot, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('zone-signal-panel-g1')),
      findsNothing,
    );

    await tester.tap(dot);
    await tester.pumpAndSettle();

    // 点指示点只展开诊断面板，不能顺带切区域焦点。
    expect(_containerOf(tester).read(zoneFocusProvider), isNull);
    expect(
      find.byKey(const ValueKey<String>('zone-signal-panel-g1')),
      findsOneWidget,
    );
    for (final text in <String>[
      '源',
      '解码',
      'DSP',
      '输出',
      '设备',
      'FLAC 44.1kHz',
      'ffmpeg',
      'EQ: rock',
      'L16 44.1kHz/16bit',
      '客厅 Soundbar',
    ]) {
      expect(find.text(text), findsOneWidget, reason: '缺少链路文本：$text');
    }
  });

  testWidgets('没有 signal_path 时隐藏指示点', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[_group(id: 'g1', name: '客厅', playerId: 'p1')],
      players: <OutputDevice>[_player('p1', '客厅 Soundbar')],
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('zone-signal-g1')), findsNothing);
  });

  testWidgets('没有任何区域时列表仍显示本机', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[],
      players: <OutputDevice>[],
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('本机'), findsOneWidget);
  });

  test('焦点写入 shared_preferences，新容器可恢复', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(zoneFocusProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(zoneFocusProvider.notifier).focus('g1');
    expect(container.read(zoneFocusProvider), 'g1');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(zoneFocusKey), 'g1');

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(zoneFocusProvider);
    await Future<void>.delayed(Duration.zero);
    expect(restored.read(zoneFocusProvider), 'g1');
  });

  Future<void> startTransfer(WidgetTester tester, _FakeOutputApi api) async {
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('zone-menu-g2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转移到此区域'));
    await tester.pump();
  }

  _FakeOutputApi transferApi() {
    return _FakeOutputApi(
      groups: <OutputGroup>[
        _group(id: 'g1', name: '客厅', playerId: 'p1'),
        _group(id: 'g2', name: '卧室', playerId: 'p2'),
      ],
      players: <OutputDevice>[
        _player('p1', '客厅 Soundbar'),
        _player('p2', '卧室 HomePod'),
      ],
    )..transferGate = Completer<void>();
  }

  testWidgets('转移中：目标行「正在切换…」、源行「正在移交」且不可点击', (tester) async {
    final api = transferApi();
    await startTransfer(tester, api);

    expect(api.transferCalls, <String>['g1->g2']);
    expect(
      find.byKey(const ValueKey<String>('zone-transfer-g2')),
      findsOneWidget,
    );
    expect(find.text('正在切换…'), findsOneWidget);
    expect(find.text('正在移交'), findsOneWidget);

    // 转移期间点行不再切焦点。
    await tester.tap(find.text('卧室'));
    await tester.pump();
    expect(_containerOf(tester).read(zoneFocusProvider), 'g1');

    api.transferGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('转移成功后焦点跟到目标区域', (tester) async {
    final api = transferApi();
    await startTransfer(tester, api);
    expect(_containerOf(tester).read(zoneFocusProvider), 'g1');

    api.transferGate!.complete();
    await tester.pumpAndSettle();

    // Roon 语义：转移完成后面板选中的区域从 A 变成 B。
    expect(_containerOf(tester).read(zoneFocusProvider), 'g2');
  });

  testWidgets('收到目标区域 state 事件后恢复交互', (tester) async {
    final events = StreamController<PlaybackEvent>.broadcast();
    addTearDown(events.close);
    final api = transferApi();

    await tester.pumpWidget(_app(api, events: events.stream));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('zone-menu-g2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转移到此区域'));
    await tester.pump();
    expect(find.text('正在切换…'), findsOneWidget);

    events.add(_stateEvent(1, 'g2'));
    await tester.pumpAndSettle();

    expect(find.text('正在切换…'), findsNothing);
    expect(find.text('正在移交'), findsNothing);

    api.transferGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('5 秒内没收到 state 事件则提示切换超时', (tester) async {
    final api = transferApi();
    await startTransfer(tester, api);
    expect(find.text('正在切换…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('切换超时，请检查设备'), findsOneWidget);
    expect(find.text('正在切换…'), findsNothing);

    api.transferGate!.complete();
    await tester.pumpAndSettle();
  });
}
