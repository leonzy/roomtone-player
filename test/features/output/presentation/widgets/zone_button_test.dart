import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/features/output/data/output_api.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/zone_button.dart';

class _FakeOutputApi extends OutputApi {
  _FakeOutputApi({required this.groups, required this.players})
    : super(dio: Dio());

  final List<OutputGroup> groups;
  final List<OutputDevice> players;

  @override
  Future<List<OutputDevice>> listPlayers() async => players;

  @override
  Future<List<OutputGroup>> playback() async => groups;
}

OutputDevice _player(String id, String name) => OutputDevice(
  id: id,
  kind: OutputKind.local,
  name: name,
  online: true,
  volume: 50,
);

OutputGroup _group({
  required String id,
  required String name,
  required String playerId,
}) => OutputGroup(
  id: id,
  name: name,
  icon: '',
  masterId: playerId,
  members: <OutputMember>[OutputMember(playerId: playerId)],
  memberCaps: <MemberCaps>[
    MemberCaps(playerId: playerId, kind: OutputKind.local, online: true),
  ],
  status: const OutputStatus(),
);

Widget _app(_FakeOutputApi api, {bool compact = false}) {
  return ProviderScope(
    overrides: [outputApiProvider.overrideWithValue(api)],
    child: MaterialApp(
      home: Scaffold(body: Center(child: ZoneButton(compact: compact))),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 区域「是否含本机」按设备 id 判断：把本机 id 设成 fake 组的成员，
    // 否则按钮会回退到「本机」哨兵。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'roomtone_device_id': 'p1',
    });
  });

  testWidgets('区域按钮在图标下方显示区域名（Roon 底栏样式）', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[_group(id: 'g1', name: '客厅', playerId: 'p1')],
      players: <OutputDevice>[_player('p1', '客厅 Soundbar')],
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('客厅'), findsOneWidget);
    final iconY =
        tester
            .getCenter(
              find.descendant(
                of: find.byType(ZoneButton),
                matching: find.byType(Icon),
              ),
            )
            .dy;
    final textY = tester.getCenter(find.text('客厅')).dy;
    expect(textY, greaterThan(iconY), reason: '区域名必须在图标下方');
  });

  testWidgets('窄播放条同样显示区域名', (tester) async {
    final api = _FakeOutputApi(
      groups: <OutputGroup>[_group(id: 'g1', name: '书房', playerId: 'p1')],
      players: <OutputDevice>[_player('p1', '书房 HomePod')],
    );

    await tester.pumpWidget(_app(api, compact: true));
    await tester.pumpAndSettle();

    expect(find.text('书房'), findsOneWidget);
  });
}
