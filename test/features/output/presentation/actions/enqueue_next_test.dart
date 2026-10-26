import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/features/library/presentation/providers/favorite_provider.dart';
import 'package:songloft_flutter/features/library/presentation/widgets/song_list_tile.dart';
import 'package:songloft_flutter/features/output/data/output_api.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/actions/enqueue_next.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/presentation/providers/zone_focus_provider.dart';
import 'package:songloft_flutter/l10n/app_localizations.dart';
import 'package:songloft_flutter/shared/models/song.dart';

class _FakeOutputApi extends OutputApi {
  _FakeOutputApi({required this.groups, required this.players})
    : super(dio: Dio());

  final List<OutputGroup> groups;
  final List<OutputDevice> players;
  final List<String> enqueueNextCalls = <String>[];

  @override
  Future<List<OutputDevice>> listPlayers() async => players;

  @override
  Future<List<OutputGroup>> playback() async => groups;

  @override
  Future<OutputStatus> enqueueNext(String groupId, List<int> songIds) async {
    enqueueNextCalls.add('$groupId:${songIds.join(',')}');
    return groups.firstWhere((group) => group.id == groupId).status;
  }
}

OutputDevice _player(String id, String name) {
  return OutputDevice(
    id: id,
    kind: OutputKind.raop,
    name: name,
    online: true,
    volume: 50,
  );
}

OutputGroup _group({
  required String id,
  required String name,
  required String playerId,
}) {
  return OutputGroup(
    id: id,
    name: name,
    masterId: playerId,
    members: <OutputMember>[OutputMember(playerId: playerId)],
    memberCaps: <MemberCaps>[
      MemberCaps(playerId: playerId, kind: OutputKind.raop, online: true),
    ],
    status: const OutputStatus(),
  );
}

Song _song() => Song(
  id: 42,
  type: 'local',
  title: '测试歌曲',
  artist: '艺术家',
  album: '专辑',
  duration: 200,
  filePath: 'music/test.mp3',
  addedAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Widget _app(_FakeOutputApi api) {
  return ProviderScope(
    overrides: [
      outputApiProvider.overrideWithValue(api),
      isSongFavoritedProvider.overrideWith((ref, id) => false),
      isRadioFavoritedProvider.overrideWith((ref, id) => false),
    ],
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 390,
            child: Consumer(
              builder:
                  (context, ref, _) => SongListTile(
                    song: _song(),
                    index: 0,
                    onTap: () {},
                    onEnqueueNext:
                        () => enqueueNextToFocusedZone(context, ref, 42),
                  ),
            ),
          ),
        ),
      ),
    ),
  );
}

_FakeOutputApi _api() {
  return _FakeOutputApi(
    groups: <OutputGroup>[_group(id: 'g1', name: '客厅', playerId: 'p1')],
    players: <OutputDevice>[_player('p1', '客厅 Soundbar')],
  );
}

ProviderContainer _containerOf(WidgetTester tester) {
  return ProviderScope.containerOf(tester.element(find.byType(SongListTile)));
}

Future<void> _openSongMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('歌曲菜单提供“下一首播放”，点击只调用一次 enqueueNext', (tester) async {
    final api = _api();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await _containerOf(tester).read(zoneFocusProvider.notifier).focus('g1');
    await tester.pump();

    await _openSongMenu(tester);
    expect(find.text('下一首播放'), findsOneWidget);

    await tester.tap(find.text('下一首播放'));
    await tester.pumpAndSettle();

    expect(api.enqueueNextCalls, <String>['g1:42']);
    expect(find.text('已加入下一首'), findsOneWidget);
  });

  testWidgets('没有焦点区域时提示先选区域，不调用 enqueueNext', (tester) async {
    final api = _api();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(_containerOf(tester).read(zoneFocusProvider), isNull);

    await _openSongMenu(tester);
    await tester.tap(find.text('下一首播放'));
    await tester.pumpAndSettle();

    expect(api.enqueueNextCalls, isEmpty);
    expect(find.text('请先选择播放区域'), findsOneWidget);
  });
}
