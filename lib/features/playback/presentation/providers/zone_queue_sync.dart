import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/models/song.dart';
import '../../../library/presentation/providers/songs_provider.dart';
import '../../../output/presentation/providers/output_provider.dart';
import '../../../output/presentation/providers/remote_zone_provider.dart';
import '../../../output/presentation/providers/zone_focus_provider.dart';
import '../../../output/presentation/widgets/zone_display.dart';
import '../../../player/domain/player_state.dart';
import '../../../player/presentation/providers/player_provider.dart';
import '../../domain/playback_event.dart';
import 'local_output_provider.dart';
import 'playback_socket_provider.dart';

/// 区域队列同步：区域拥有队列，客户端只是编辑器。
///
/// Roon 的模型是「先选区域，再播放」：每个区域有自己的队列，切换区域时
/// 整个播放器（队列 + 正在播放 + 进度）跟着切过去。这里把这条规则落到客户端：
///
/// - 焦点区域变化 → 拉该区域的队列，接管为本地队列
/// - 本地改队列（选歌 / 拖拽 / 删除）→ 整条推给服务端
/// - 焦点区域不含本机 → 把该区域的服务端状态镜像到播放器 UI
///
/// 出声仍由本机（local sink）或服务端解码（raop/dlna）负责，本类不碰音频。
class ZoneQueueSync {
  ZoneQueueSync(this._ref);

  final Ref _ref;

  /// 最近一次与服务端对齐过的队列，用来避免回环推送。
  List<int> _pushedSongs = const <int>[];
  int _pushedIndex = -1;

  /// 已经接管过的区域：输出状态每次刷新都会重建 [ZoneEntry]，
  /// 用 id 判重避免反复拉队列覆盖用户正在编辑的内容。
  String? _adoptedFor;

  /// 接管进行中：这期间本地队列还是上一个区域的，不能推给新区域。
  bool _adopting = false;
  int _adoptGeneration = 0;

  final Map<String, Timer> _pendingPushes = {};
  StreamSubscription<PlayerState>? _localSubscription;

  /// 远端区域在播放时按秒推进进度条（服务端不推送位置）。
  Timer? _remoteTick;
  Timer? _identityRefresh;
  bool _disposed = false;

  void start() {
    _ref.listen<String?>(
      zoneFocusProvider,
      (_, _) => unawaited(_syncFocus()),
      fireImmediately: true,
    );
    // 区域列表是异步加载的：焦点先到、组后到时也要补一次接管。
    _ref.listen<OutputState>(
      outputControllerProvider,
      (_, _) => unawaited(_syncFocus()),
    );

    _ref.listen<PlayerState>(playerStateProvider, (prev, next) {
      if (identical(prev?.playlist, next.playlist) &&
          prev?.currentIndex == next.currentIndex) {
        return;
      }
      _schedulePush(next);
    });

    _localSubscription = _ref
        .read(playerStateProvider.notifier)
        .localOutputStates
        .listen((state) {
          final zones = buildZoneEntries(
            _ref.read(outputControllerProvider),
            localDeviceId: _ref.read(localDeviceIdProvider),
          );
          for (final zone in zones) {
            if (zone.isLocal && zone.isReal) {
              _queuePush(zone.id, state);
              break;
            }
          }
        });

    _ref.listen<AsyncValue<PlaybackEvent>>(playbackEventsProvider, (_, next) {
      final event = next.value;
      if (event != null) _onPlaybackEvent(event);
    });
  }

  void dispose() {
    _disposed = true;
    for (final timer in _pendingPushes.values) {
      timer.cancel();
    }
    _pendingPushes.clear();
    unawaited(_localSubscription?.cancel());

    _remoteTick?.cancel();
    _identityRefresh?.cancel();
  }

  ZoneEntry? _focusedZone() {
    final state = _ref.read(outputControllerProvider);
    return resolveFocusedZone(
      state,
      _ref.read(zoneFocusProvider),
      localDeviceId: _ref.read(localDeviceIdProvider),
    );
  }

  /// 焦点区域变了（或区域列表刚加载出来）就接管它的队列。
  Future<void> _syncFocus() async {
    if (_disposed) return;
    final zone = _focusedZone();
    // 播放器据此决定「本机出声」还是「把命令发给服务端」。
    _ref
        .read(remoteZoneIdProvider.notifier)
        .set(zone != null && zone.isReal && !zone.isLocal ? zone.id : null);
    if (zone == null) {
      ++_adoptGeneration;
      _adoptedFor = null;
      _adopting = false;

      _syncRemoteTick(null);
      return;
    }
    if (!zone.isReal) {
      ++_adoptGeneration;
      _adopting = false;

      // 本机还没注册成服务端区域：没有可同步的队列，保持本地队列。
      _adoptedFor = null;
      _syncRemoteTick(zone);
      return;
    }
    if (_adoptedFor == zone.id) {
      _syncRemoteTick(zone);
      return;
    }
    _adoptedFor = zone.id;

    final generation = ++_adoptGeneration;
    await _adopt(zone, generation);
    if (generation == _adoptGeneration) _syncRemoteTick(zone);
  }

  /// 远端区域在播放时启动本地进度推进；回到本机区域或暂停时停掉。
  void _syncRemoteTick(ZoneEntry? zone) {
    final playing = _ref.read(playerStateProvider).isPlaying;
    final shouldTick = zone != null && zone.isReal && !zone.isLocal && playing;
    if (!shouldTick) {
      _remoteTick?.cancel();
      _remoteTick = null;
      return;
    }
    _remoteTick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      final current = _focusedZone();
      if (current == null || !current.isReal || current.isLocal) {
        _remoteTick?.cancel();
        _remoteTick = null;
        return;
      }
      _ref
          .read(playerStateProvider.notifier)
          .advanceRemotePosition(const Duration(seconds: 1));
    });
  }

  /// 切到某个区域：把该区域的队列接管为本地队列。
  Future<void> _adopt(ZoneEntry zone, int generation) async {
    _adopting = true;
    try {
      final status = await _ref.read(outputApiProvider).getQueue(zone.id);
      if (_disposed || generation != _adoptGeneration) return;
      final ids = status.queue.items;
      if (ids.isEmpty) {
        _pushedSongs = const <int>[];
        _pushedIndex = -1;
        await _ref
            .read(playerStateProvider.notifier)
            .adoptZoneQueue(const <Song>[], localZone: zone.isLocal);
        return;
      }
      final songs = await _ref.read(songsApiProvider).getSongsByIds(ids);
      if (_disposed || generation != _adoptGeneration) return;
      _pushedSongs = ids;
      _pushedIndex = status.queue.current;
      await _ref
          .read(playerStateProvider.notifier)
          .adoptZoneQueue(
            songs,
            index: status.queue.current,
            position: Duration(milliseconds: (status.position * 1000).round()),
            // 只有本机参与的区域才由本机出声；别的区域只切 UI。
            autoPlay: zone.isLocal && status.isPlaying,
            localZone: zone.isLocal,
            mirrorPlaying: !zone.isLocal && status.isPlaying,
          );
    } catch (e) {
      // 拉不到就允许下次输出刷新时重试。
      if (generation == _adoptGeneration) _adoptedFor = null;
      debugPrint('[ZoneQueueSync] adopt ${zone.id} failed: $e');
    } finally {
      if (generation == _adoptGeneration) _adopting = false;
    }
  }

  /// 焦点区域不含本机时，把服务端状态镜像到播放器 UI（本机不出声）。
  void _onPlaybackEvent(PlaybackEvent event) {
    if (const {
      'speaker_seen',
      'group_changed',
      'member_changed',
    }.contains(event.type)) {
      _identityRefresh?.cancel();
      _identityRefresh = Timer(const Duration(milliseconds: 80), () {
        if (!_disposed) {
          unawaited(
            _ref.read(outputControllerProvider.notifier).refresh(silent: true),
          );
        }
      });
      return;
    }
    if (event.type != 'state') return;
    final zone = _focusedZone();
    if (zone == null || !zone.isReal || zone.isLocal) return;
    if (event.groupId != zone.id) return;
    _ref
        .read(playerStateProvider.notifier)
        .applyRemoteZoneStatus(
          playing: event.status == 'playing',
          position: Duration(milliseconds: event.positionMs),
        );
    _syncRemoteTick(zone);
  }

  void _schedulePush(PlayerState state) {
    if (_disposed || _adopting) return;
    final zone = _focusedZone();
    if (zone == null || !zone.isReal) return;
    _queuePush(zone.id, state);
  }

  void _queuePush(String zoneId, PlayerState state) {
    if (_disposed) return;
    _pendingPushes.remove(zoneId)?.cancel();
    _pendingPushes[zoneId] = Timer(const Duration(milliseconds: 250), () {
      _pendingPushes.remove(zoneId);
      unawaited(_push(zoneId, state));
    });
  }

  Future<void> _push(String zoneId, PlayerState state) async {
    if (_disposed) return;
    final isFocused = _focusedZone()?.id == zoneId;
    final ids = state.playlist.map((s) => s.id).toList(growable: false);
    final index =
        ids.isEmpty ? -1 : (state.currentIndex < 0 ? 0 : state.currentIndex);
    if (isFocused && listEquals(ids, _pushedSongs) && index == _pushedIndex) {
      return;
    }
    if (isFocused) {
      _pushedSongs = ids;
      _pushedIndex = index;
    }
    try {
      await _ref
          .read(outputApiProvider)
          .replaceQueue(zoneId, ids, index: index < 0 ? 0 : index);
    } catch (e) {
      debugPrint('[ZoneQueueSync] push $zoneId failed: $e');
    }
  }
}

/// 全局单例：在 App 根部 watch 一次即可常驻。
///
/// 与 [localOutputProvider] 一样受 [playbackBackgroundEnabledProvider] 控制：
/// widget 测试里关掉，避免真实网络请求与防抖定时器在测试结束后仍 pending。
final zoneQueueSyncProvider = Provider<ZoneQueueSync>((ref) {
  // 常驻同步器：被回收会丢掉 _adoptedFor/_pushedSongs 对齐记录，
  // 重建后立刻重新接管焦点区域并 seek，正在播的歌会被拽回服务端位置。
  ref.keepAlive();
  final sync = ZoneQueueSync(ref);
  if (ref.watch(playbackBackgroundEnabledProvider)) sync.start();
  ref.onDispose(sync.dispose);
  return sync;
});
