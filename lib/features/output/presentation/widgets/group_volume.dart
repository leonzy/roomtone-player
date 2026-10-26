import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/output_models.dart';
import '../providers/output_provider.dart';

/// 打开组音量弹层。
Future<void> showGroupVolumeSheet(
  BuildContext context,
  String groupId, {
  String title = '组音量',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder:
        (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                GroupVolumeControl(groupId: groupId),
              ],
            ),
          ),
        ),
  );
}

/// 组音量控制：一个基准滑杆 + 每个成员的 ±10 微调。
///
/// 语义（docs/architecture_playback.md §7.1）：
/// - 组滑杆提交的是**基准音量**，服务端给每台设备下发
///   `clamp(base + volume_offset)`；
/// - 成员 ±10 改的是该成员的 `volume_offset`，随后重新下发一次组音量，
///   让实际音量立刻变成 `clamp(base + 新 offset)`；
/// - 部分设备失败时服务端不回滚已成功的成员，这里只列出失败项，
///   不把滑杆拽回旧值。
class GroupVolumeControl extends ConsumerStatefulWidget {
  const GroupVolumeControl({
    super.key,
    required this.groupId,
    this.showMembers = true,
  });

  final String groupId;

  /// 是否显示成员微调行。窄面板里可以只保留组滑杆。
  final bool showMembers;

  @override
  ConsumerState<GroupVolumeControl> createState() => _GroupVolumeControlState();
}

class _GroupVolumeControlState extends ConsumerState<GroupVolumeControl> {
  GroupVolume? _volume;
  bool _loading = true;
  String _error = '';
  double _base = 0;
  Timer? _debounce;
  final Set<String> _adjusting = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(covariant GroupVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _debounce?.cancel();
      _volume = null;
      _loading = true;
      _error = '';
      _base = 0;
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final controller = ref.read(outputControllerProvider.notifier);
    final volume = await controller.groupVolume(widget.groupId);
    if (!mounted) return;
    if (volume == null) {
      setState(() {
        _loading = false;
        _error = ref.read(outputControllerProvider).error;
      });
      return;
    }
    setState(() {
      _loading = false;
      _error = '';
      _volume = volume;
      _base = volume.volume.toDouble().clamp(0, 100).toDouble();
    });
  }

  void _onBaseChanged(double value) {
    setState(() => _base = value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _debounce = null;
      _commitBase();
    });
  }

  void _onBaseChangeStart(double _) {}

  void _onBaseChangeEnd(double _) {
    _debounce?.cancel();
    _debounce = null;
    _commitBase();
  }

  Future<void> _commitBase() async {
    final base = _base.round().clamp(0, 100).toInt();
    final controller = ref.read(outputControllerProvider.notifier);
    final result = await controller.setGroupVolume(widget.groupId, base);
    if (!mounted) return;
    if (result == null) {
      setState(() => _error = ref.read(outputControllerProvider).error);
      return;
    }
    setState(() {
      _error = '';
      _volume = result;
      // 服务端会钳位；以返回值为准，避免滑杆停在越界值。
      _base = result.volume.toDouble().clamp(0, 100).toDouble();
    });
  }

  Future<void> _adjustMember(GroupVolumeMember member, int delta) async {
    if (_adjusting.contains(member.playerId)) return;
    final nextOffset = (member.volumeOffset + delta).clamp(-100, 100).toInt();
    if (nextOffset == member.volumeOffset) return;

    setState(() => _adjusting.add(member.playerId));
    final controller = ref.read(outputControllerProvider.notifier);
    final ok = await controller.updateMember(
      widget.groupId,
      member.playerId,
      volumeOffset: nextOffset,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _adjusting.remove(member.playerId);
        _error = ref.read(outputControllerProvider).error;
      });
      return;
    }
    // 偏移只是配置；重新下发一次组音量，实际音量才会变成
    // clamp(base + 新 offset)。
    final result = await controller.setGroupVolume(
      widget.groupId,
      _base.round().clamp(0, 100).toInt(),
    );
    if (!mounted) return;
    setState(() {
      _adjusting.remove(member.playerId);
      if (result != null) {
        _volume = result;
        _base = result.volume.toDouble().clamp(0, 100).toDouble();
        _error = '';
      } else {
        _error = ref.read(outputControllerProvider).error;
      }
    });
  }

  String _memberName(String playerId) {
    final state = ref.read(outputControllerProvider);
    return state.playerOf(playerId)?.displayName ?? playerId;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final volume = _volume;
    final failed = volume?.failed ?? const <GroupVolumeMember>[];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.volume_up_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text('组音量', style: theme.textTheme.titleSmall),
            const Spacer(),
            Text(
              '${_base.round()}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Slider(
          key: const Key('group-volume-slider'),
          value: _base.clamp(0, 100).toDouble(),
          min: 0,
          max: 100,
          divisions: 100,
          label: '${_base.round()}',
          onChanged: _loading ? null : _onBaseChanged,
          onChangeStart: _loading ? null : _onBaseChangeStart,
          onChangeEnd: _loading ? null : _onBaseChangeEnd,
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (widget.showMembers && volume != null)
          for (final member in volume.members)
            _MemberVolumeRow(
              key: ValueKey<String>('group-volume-member-${member.playerId}'),
              name: _memberName(member.playerId),
              member: member,
              busy: _adjusting.contains(member.playerId),
              onMinus: () => _adjustMember(member, -10),
              onPlus: () => _adjustMember(member, 10),
            ),
        if (failed.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${failed.length} 台设备音量下发失败（已成功的成员不回滚）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                for (final member in failed)
                  Text(
                    '${_memberName(member.playerId)}'
                    '${member.error.isEmpty ? '' : '：${member.error}'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MemberVolumeRow extends StatelessWidget {
  const _MemberVolumeRow({
    super.key,
    required this.name,
    required this.member,
    required this.busy,
    required this.onMinus,
    required this.onPlus,
  });

  final String name;
  final GroupVolumeMember member;
  final bool busy;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offset = member.volumeOffset;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            '${member.volume}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: member.ok ? null : theme.colorScheme.error,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${offset >= 0 ? '+' : ''}$offset',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          IconButton(
            key: ValueKey<String>('group-volume-minus-${member.playerId}'),
            tooltip: '音量 -10',
            visualDensity: VisualDensity.compact,
            onPressed: busy ? null : onMinus,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
          ),
          IconButton(
            key: ValueKey<String>('group-volume-plus-${member.playerId}'),
            tooltip: '音量 +10',
            visualDensity: VisualDensity.compact,
            onPressed: busy ? null : onPlus,
            icon: const Icon(Icons.add_circle_outline, size: 20),
          ),
        ],
      ),
    );
  }
}
