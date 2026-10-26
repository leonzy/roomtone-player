import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';

/// 播放调音面板：交叉淡化 + ReplayGain。
///
/// 两者都作用在**服务端解码路径**上（RAOP / DLNA 设备不认播放器侧的
/// `replay_gain` 与 `trans_type`），改完下一曲生效，当前正在播的曲不受影响。
///
/// 交叉淡化与 gapless 互斥：开启后交界处走普通 Open，不再接续解码器。
/// 这一点必须写在界面上，否则用户会以为是 bug（"怎么无缝没了"）。
Future<void> showPlaybackTuningSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder:
        (_) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: PlaybackTuningSheet(),
        ),
  );
}

class PlaybackTuningSheet extends ConsumerStatefulWidget {
  const PlaybackTuningSheet({super.key});

  @override
  ConsumerState<PlaybackTuningSheet> createState() =>
      _PlaybackTuningSheetState();
}

class _PlaybackTuningSheetState extends ConsumerState<PlaybackTuningSheet> {
  CrossfadeSetting? _crossfade;
  ReplayGainSetting? _replayGain;
  bool _loading = true;
  bool _saving = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(outputApiProvider);
    try {
      final results = await Future.wait([
        api.getCrossfadeSetting(),
        api.getReplayGainSetting(),
      ]);
      if (!mounted) return;
      setState(() {
        _crossfade = results[0] as CrossfadeSetting;
        _replayGain = results[1] as ReplayGainSetting;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _saveCrossfade(CrossfadeSetting next) async {
    final prev = _crossfade;
    setState(() {
      _crossfade = next;
      _saving = true;
      _error = '';
    });
    try {
      final saved = await ref
          .read(outputApiProvider)
          .updateCrossfadeSetting(next);
      if (!mounted) return;
      setState(() => _crossfade = saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _crossfade = prev;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveReplayGain(ReplayGainSetting next) async {
    final prev = _replayGain;
    setState(() {
      _replayGain = next;
      _saving = true;
      _error = '';
    });
    try {
      final saved = await ref
          .read(outputApiProvider)
          .updateReplayGainSetting(next);
      if (!mounted) return;
      setState(() => _replayGain = saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _replayGain = prev;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final crossfade = _crossfade ?? const CrossfadeSetting();
    final rg = _replayGain ?? const ReplayGainSetting();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('播放调音', style: theme.textTheme.titleLarge),
                ),
                if (_saving)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 8),

            Text('交叉淡化', style: theme.textTheme.titleSmall),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: crossfade.enabled,
              onChanged:
                  _saving
                      ? null
                      : (v) => _saveCrossfade(crossfade.copyWith(enabled: v)),
              title: const Text('两曲交界处淡入淡出'),
              subtitle: const Text('开启后不再无缝接续（gapless），交界处等功率混合'),
            ),
            if (crossfade.enabled) ...[
              Row(
                children: [
                  const Text('淡化时长'),
                  Expanded(
                    child: Slider(
                      value: crossfade.seconds.clamp(0.5, 12).toDouble(),
                      min: 0.5,
                      max: 12,
                      divisions: 23,
                      label: '${crossfade.seconds.toStringAsFixed(1)} 秒',
                      onChanged:
                          _saving
                              ? null
                              : (v) => setState(
                                () =>
                                    _crossfade = crossfade.copyWith(seconds: v),
                              ),
                      onChangeEnd:
                          _saving
                              ? null
                              : (v) => _saveCrossfade(
                                crossfade.copyWith(seconds: v),
                              ),
                    ),
                  ),
                  Text('${crossfade.seconds.toStringAsFixed(1)}s'),
                ],
              ),
              Text(
                '改完下一曲生效；当前播放的曲目不受影响',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],

            const Divider(height: 32),

            Text('响度均衡（ReplayGain）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'off', label: Text('关闭')),
                ButtonSegment(value: 'track', label: Text('单曲')),
                ButtonSegment(value: 'album', label: Text('专辑')),
              ],
              selected: {rg.mode},
              onSelectionChanged:
                  _saving
                      ? null
                      : (v) => _saveReplayGain(rg.copyWith(mode: v.first)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: rg.preventClipping,
              onChanged:
                  _saving || rg.mode == 'off'
                      ? null
                      : (v) => _saveReplayGain(rg.copyWith(preventClipping: v)),
              title: const Text('防削波'),
              subtitle: const Text('按 peak 标签限制正增益，宁可少提也不削波'),
            ),
            Text(
              '标签在首次播放该曲时读取并缓存，不需要重新扫描曲库；'
              '专辑模式缺少专辑增益时退回单曲增益',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
