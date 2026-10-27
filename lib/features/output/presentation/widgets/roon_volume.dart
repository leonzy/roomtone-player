import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';

/// Each slider changes only its speaker. Group +/- retains member offsets.
class RoonGroupVolumeControl extends ConsumerStatefulWidget {
  const RoonGroupVolumeControl({super.key, required this.groupId});
  final String groupId;
  @override
  ConsumerState<RoonGroupVolumeControl> createState() =>
      _RoonGroupVolumeControlState();
}

class _RoonGroupVolumeControlState
    extends ConsumerState<RoonGroupVolumeControl> {
  GroupVolume? _volume;
  String _error = '';
  bool _busy = false;
  int _generation = 0;
  final _drafts = <String, int>{};
  final _pending = <String, int>{};
  final _timers = <String, Timer>{};

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void didUpdateWidget(covariant RoonGroupVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId == widget.groupId) return;
    _resetZone();
  }

  void _resetZone() {
    _generation++;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
    _drafts.clear();
    setState(() {
      _volume = null;
      _busy = false;
      _error = '';
    });
    _load();
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final generation = _generation;
    final result = await ref
        .read(outputControllerProvider.notifier)
        .groupVolume(widget.groupId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _volume = result;
      _error = result == null ? ref.read(outputControllerProvider).error : '';
    });
  }

  void _change(String id, int value, {bool commit = false}) {
    setState(() => _drafts[id] = value.clamp(0, 100));
    _timers.remove(id)?.cancel();
    if (commit) {
      _pending[id] = value.clamp(0, 100);
      _flush();
    } else {
      _timers[id] = Timer(const Duration(milliseconds: 250), () {
        _pending[id] = _drafts[id]!;
        _flush();
      });
    }
  }

  Future<void> _flush() async {
    if (_busy) return;
    final generation = _generation;
    final groupId = widget.groupId;
    setState(() => _busy = true);
    while (mounted && _pending.isNotEmpty) {
      final id = _pending.keys.first;
      final value = _pending.remove(id)!;
      final ok = await ref
          .read(outputControllerProvider.notifier)
          .setMemberVolume(groupId, id, value);
      if (!mounted || generation != _generation) return;
      if (!ok) {
        setState(() => _error = ref.read(outputControllerProvider).error);
        break;
      }
      if (!_pending.containsKey(id) && _drafts[id] == value) _drafts.remove(id);
      await _load();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _groupChange({int delta = 0, bool? muted}) async {
    if (_busy || _volume == null) return;
    final generation = _generation;
    setState(() => _busy = true);
    final result = await ref
        .read(outputControllerProvider.notifier)
        .setGroupVolume(
          widget.groupId,
          (_volume!.volume + delta).clamp(0, 100),
          muted: muted ?? false,
        );
    if (!mounted || generation != _generation) return;
    setState(() {
      _busy = false;
      if (result != null) {
        _volume = result;
        _error = '';
      } else {
        _error = ref.read(outputControllerProvider).error;
      }
    });
    if (_pending.isNotEmpty) _flush();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(
      outputControllerProvider.select(
        (s) => s.groupOf(widget.groupId)?.memberIds.join('|') ?? '',
      ),
      (previous, next) {
        if (previous != next) _resetZone();
      },
    );
    final state = ref.watch(outputControllerProvider);
    final theme = Theme.of(context);
    final volume = _volume;
    if (volume == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child:
            _error.isEmpty
                ? const LinearProgressIndicator()
                : TextButton(onPressed: _load, child: Text('$_error · 重试')),
      );
    }
    final grouped = volume.members.length > 1;
    final allMuted =
        volume.members.isNotEmpty &&
        volume.members.every((m) => state.playerOf(m.playerId)?.muted == true);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final member in volume.members) ...[
          if (grouped)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
              child: Text(
                state.playerOf(member.playerId)?.displayName ?? member.playerId,
              ),
            ),
          _SpeakerVolumeSlider(
            key: ValueKey('speaker-volume-${member.playerId}'),
            name:
                state.playerOf(member.playerId)?.displayName ?? member.playerId,
            value: _drafts[member.playerId] ?? member.volume,
            muted: state.playerOf(member.playerId)?.muted ?? false,
            onChanged: (v) => _change(member.playerId, v),
            onCommit: (v) => _change(member.playerId, v, commit: true),
            onMute:
                _busy
                    ? null
                    : () async {
                      final generation = _generation;
                      setState(() => _busy = true);
                      final ok = await ref
                          .read(outputControllerProvider.notifier)
                          .setVolume(
                            member.playerId,
                            member.volume,
                            muted:
                                !(state.playerOf(member.playerId)?.muted ??
                                    false),
                          );
                      if (!mounted || generation != _generation) return;
                      setState(() {
                        _busy = false;
                        _error =
                            ok ? '' : ref.read(outputControllerProvider).error;
                      });
                      if (_pending.isNotEmpty) _flush();
                    },
          ),
        ],
        if (grouped) ...[
          const Divider(height: 20),
          Row(
            children: [
              TextButton.icon(
                key: const Key('group-mute'),
                onPressed: _busy ? null : () => _groupChange(muted: !allMuted),
                icon: Icon(
                  allMuted
                      ? Icons.volume_off_outlined
                      : Icons.volume_up_outlined,
                ),
                label: Text(allMuted ? '取消全部静音' : '全部静音'),
              ),
              const Spacer(),
              IconButton(
                key: const Key('group-volume-down'),
                tooltip: '全部音量 -1',
                onPressed: _busy ? null : () => _groupChange(delta: -1),
                icon: const Icon(Icons.remove_circle),
              ),
              IconButton(
                key: const Key('group-volume-up'),
                tooltip: '全部音量 +1',
                onPressed: _busy ? null : () => _groupChange(delta: 1),
                icon: const Icon(Icons.add_circle),
              ),
            ],
          ),
        ],
        if (_error.isNotEmpty)
          Text(_error, style: TextStyle(color: theme.colorScheme.error)),
        for (final failed in volume.failed)
          Text(
            '${state.playerOf(failed.playerId)?.displayName ?? failed.playerId}：${failed.error}',
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }
}

class _SpeakerVolumeSlider extends StatelessWidget {
  const _SpeakerVolumeSlider({
    super.key,
    required this.name,
    required this.value,
    required this.muted,
    required this.onChanged,
    required this.onCommit,
    this.onMute,
  });
  final String name;
  final int value;
  final bool muted;
  final ValueChanged<int> onChanged, onCommit;
  final VoidCallback? onMute;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        IconButton(
          tooltip: muted ? '取消$name静音' : '$name静音',
          onPressed: onMute,
          icon: Icon(muted ? Icons.volume_off : Icons.volume_up, size: 20),
        ),
        SizedBox(width: 28, child: Text('$value')),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                semanticFormatterCallback: (v) => '$name 音量 ${v.round()}',
                value: value.toDouble().clamp(0, 100),
                min: 0,
                max: 100,
                divisions: 100,
                onChanged: (v) => onChanged(v.round()),
                onChangeEnd: (v) => onCommit(v.round()),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0', style: Theme.of(context).textTheme.labelSmall),
                    Text('100', style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '$name音量 -1',
          onPressed: value > 0 ? () => onCommit(value - 1) : null,
          icon: const Icon(Icons.remove_circle, size: 24),
        ),
        IconButton(
          tooltip: '$name音量 +1',
          onPressed: value < 100 ? () => onCommit(value + 1) : null,
          icon: const Icon(Icons.add_circle, size: 24),
        ),
      ],
    ),
  );
}
