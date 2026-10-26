import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/features/output/presentation/providers/zone_focus_provider.dart';
import 'package:songloft_flutter/features/playback/domain/playback_event.dart';
import 'package:songloft_flutter/features/playback/presentation/providers/playback_socket_provider.dart';

PlaybackEvent _event({
  required int seq,
  required String groupId,
  String type = 'state',
  String status = 'playing',
}) {
  return PlaybackEvent.fromJson(<String, dynamic>{
    'seq': seq,
    'type': type,
    'time_ms': seq,
    'group_id': groupId,
    'status': status,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<PlaybackEvent> events;
  late DateTime now;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    events = StreamController<PlaybackEvent>.broadcast();
    now = DateTime(2026, 1, 1, 12);
    container = ProviderContainer(
      overrides: [
        playbackEventsProvider.overrideWith((ref) => events.stream),
        zoneAutoFollowClockProvider.overrideWithValue(() => now),
      ],
    );
    // 生产环境由 SongloftApp 常驻监听；测试里也要保持订阅，
    // 否则 Riverpod 会暂停 notifier 内部的 ref.listen。
    container.listen(zoneAutoFollowProvider, (_, _) {});
    // 先销毁容器再关流：Riverpod 的订阅只在容器销毁时取消，
    // 反过来会让 events.close() 一直等 done 而超时。
    addTearDown(() async {
      container.dispose();
      await events.close();
    });
  });

  Future<void> emit(PlaybackEvent event) async {
    events.add(event);
    await pumpEventQueue();
  }

  Future<void> enableAutoFollow() async {
    await container.read(zoneAutoFollowProvider.notifier).setAutoFollow(true);
  }

  test('autoFollow 默认关闭：其他区域开始播放不切焦点', () async {
    container.read(zoneAutoFollowProvider);
    expect(container.read(zoneAutoFollowProvider), isFalse);
    await container.read(zoneFocusProvider.notifier).focus('g1');

    await emit(_event(seq: 1, groupId: 'g2'));

    expect(container.read(zoneFocusProvider), 'g1');
  });

  test('autoFollow 开启：其他区域开始播放时切到该区域', () async {
    await enableAutoFollow();
    await container.read(zoneFocusProvider.notifier).focus('g1');

    await emit(_event(seq: 1, groupId: 'g2'));

    expect(container.read(zoneFocusProvider), 'g2');
  });

  test('autoFollow 开启：同一区域开始播放不切焦点', () async {
    await enableAutoFollow();
    await container.read(zoneFocusProvider.notifier).focus('g2');

    await emit(_event(seq: 1, groupId: 'g2'));

    expect(container.read(zoneFocusProvider), 'g2');
  });

  test('autoFollow 开启：非 playing / 非 state 事件不切焦点', () async {
    await enableAutoFollow();
    await container.read(zoneFocusProvider.notifier).focus('g1');

    await emit(_event(seq: 1, groupId: 'g2', status: 'paused'));
    await emit(_event(seq: 2, groupId: 'g2', type: 'target_changed'));

    expect(container.read(zoneFocusProvider), 'g1');
  });

  test('同一 groupId 300ms 内重复事件只处理一次', () async {
    await enableAutoFollow();
    await container.read(zoneFocusProvider.notifier).focus('g1');

    await emit(_event(seq: 1, groupId: 'g2'));
    expect(container.read(zoneFocusProvider), 'g2');

    // 手动切走，模拟用户在 300ms 内又点了别的区域。
    await container.read(zoneFocusProvider.notifier).focus('g1');

    now = now.add(const Duration(milliseconds: 100));
    await emit(_event(seq: 2, groupId: 'g2'));
    expect(container.read(zoneFocusProvider), 'g1');

    // 超过 300ms 后同一区域再次开始播放，允许重新跟随。
    now = now.add(const Duration(milliseconds: 250));
    await emit(_event(seq: 3, groupId: 'g2'));
    expect(container.read(zoneFocusProvider), 'g2');
  });

  test('开关写入 shared_preferences，新容器可恢复', () async {
    container.read(zoneAutoFollowProvider);
    await container.read(zoneAutoFollowProvider.notifier).setAutoFollow(true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(zoneAutoFollowKey), isTrue);

    final restored = ProviderContainer(
      overrides: [
        playbackEventsProvider.overrideWith(
          (ref) => const Stream<PlaybackEvent>.empty(),
        ),
      ],
    );
    restored.listen(zoneAutoFollowProvider, (_, _) {});
    addTearDown(restored.dispose);
    await pumpEventQueue();

    expect(restored.read(zoneAutoFollowProvider), isTrue);
  });
}
