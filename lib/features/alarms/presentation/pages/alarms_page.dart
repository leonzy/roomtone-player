import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/utils/responsive_snackbar.dart';
import '../../../output/presentation/providers/output_provider.dart';
import '../../../output/presentation/widgets/zone_display.dart';
import '../../../playlist/domain/playlist.dart';
import '../../../playlist/presentation/providers/playlist_provider.dart';
import '../../domain/alarm_models.dart';
import '../providers/alarm_provider.dart';

/// 闹钟管理页：列表 + 新建 / 编辑 / 启停 / 试听 / 删除。
///
/// 调度完全在服务端（15 秒一轮，到点在目标组起播歌单并渐强音量），
/// 页面关掉也照常响。时间按本地 `HH:MM` 保存，不做时区换算。
class AlarmsPage extends ConsumerStatefulWidget {
  const AlarmsPage({super.key});

  @override
  ConsumerState<AlarmsPage> createState() => _AlarmsPageState();
}

class _AlarmsPageState extends ConsumerState<AlarmsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(alarmControllerProvider.notifier).load();
      // 输出列表用于把 target_id 显示成设备 / 组名。
      ref.read(outputControllerProvider.notifier).refresh();
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ResponsiveSnackBar.show(context, message: message);
  }

  Future<void> _openEditor({Alarm? alarm}) async {
    final draft = alarm?.toDraft();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AlarmEditorDialog(initial: draft, alarmId: alarm?.id),
    );
    if (saved == true) {
      final s = ref.read(alarmControllerProvider);
      _toast(s.error.isNotEmpty ? s.error : s.notice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(alarmControllerProvider);
    final output = ref.watch(outputControllerProvider);
    final controller = ref.read(alarmControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('闹钟'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: controller.load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.busy ? null : () => _openEditor(),
        icon: const Icon(Icons.add_alarm),
        label: const Text('新建闹钟'),
      ),
      body:
          state.loading && state.items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: controller.load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  children: [
                    if (state.error.isNotEmpty)
                      _Banner(
                        text: state.error,
                        color: theme.colorScheme.errorContainer,
                        onClose: controller.clearError,
                      ),
                    if (state.notice.isNotEmpty)
                      _Banner(
                        text: state.notice,
                        color: theme.colorScheme.secondaryContainer,
                        onClose: controller.clearNotice,
                      ),
                    if (state.items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          children: [
                            Icon(
                              Icons.alarm_off,
                              size: 48,
                              color: theme.colorScheme.outline,
                            ),
                            const SizedBox(height: 12),
                            Text('还没有闹钟', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text(
                              '到点会在选定的设备/组上起播歌单，并渐强到设定音量',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    for (final alarm in state.items)
                      _AlarmCard(
                        alarm: alarm,
                        targetLabel: _targetLabel(output, alarm.targetId),
                        busy: state.busy,
                        onToggle:
                            (v) => controller
                                .toggle(alarm, v)
                                .then(
                                  (_) => _toast(
                                    ref.read(alarmControllerProvider).error,
                                  ),
                                ),
                        onTest:
                            () => controller.trigger(alarm.id).then((_) {
                              final s = ref.read(alarmControllerProvider);
                              _toast(s.error.isNotEmpty ? s.error : s.notice);
                            }),
                        onEdit: () => _openEditor(alarm: alarm),
                        onDelete: () async {
                          final ok = await controller.delete(alarm.id);
                          final s = ref.read(alarmControllerProvider);
                          _toast(ok ? s.notice : s.error);
                        },
                      ),
                  ],
                ),
              ),
    );
  }

  String _targetLabel(OutputState output, String targetId) {
    final device = output.playerOf(targetId);
    if (device != null) return device.name.isEmpty ? device.id : device.name;
    for (final g in output.groups) {
      if (g.id == targetId) return g.isSolo ? '单机播放' : g.name;
    }
    return targetId;
  }
}

class _AlarmCard extends StatelessWidget {
  const _AlarmCard({
    required this.alarm,
    required this.targetLabel,
    required this.busy,
    required this.onToggle,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  final Alarm alarm;
  final String targetLabel;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      AlarmDays.describe(alarm.daysMask),
      targetLabel,
      alarm.playlistId > 0 ? '歌单 #${alarm.playlistId}' : '只调音量',
      '音量 ${alarm.volume}',
      if (alarm.fadeSeconds > 0) '渐强 ${alarm.fadeSeconds}s',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          ListTile(
            leading: Text(
              alarm.timeOfDay,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color:
                    alarm.enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
              ),
            ),
            title: Text(
              alarm.name.isEmpty ? '闹钟' : alarm.name,
              style: TextStyle(
                color: alarm.enabled ? null : theme.colorScheme.outline,
              ),
            ),
            subtitle: Text(parts.join(' · ')),
            trailing: Switch(
              value: alarm.enabled,
              onChanged: busy ? null : onToggle,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: busy ? null : onTest,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('试听'),
              ),
              TextButton.icon(
                onPressed: busy ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('编辑'),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 新建 / 编辑对话框。
class _AlarmEditorDialog extends ConsumerStatefulWidget {
  const _AlarmEditorDialog({this.initial, this.alarmId});

  final AlarmDraft? initial;

  /// 编辑态要更新的闹钟 id；新建为 null。
  final String? alarmId;

  @override
  ConsumerState<_AlarmEditorDialog> createState() => _AlarmEditorDialogState();
}

class _AlarmEditorDialogState extends ConsumerState<_AlarmEditorDialog> {
  late AlarmDraft _draft = widget.initial ?? const AlarmDraft();
  late final TextEditingController _name = TextEditingController(
    text: _draft.name,
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final parts = _draft.timeOfDay.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 7,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 30) : 30,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    setState(() => _draft = _draft.copyWith(timeOfDay: '$hh:$mm'));
  }

  Future<void> _save() async {
    if (_draft.targetId.isEmpty) {
      setState(() => _error = '请选择播放目标（设备或同步组）');
      return;
    }
    final controller = ref.read(alarmControllerProvider.notifier);
    final draft = _draft.copyWith(name: _name.text.trim());
    final ok =
        widget.alarmId == null
            ? await controller.create(draft)
            : await controller.update(widget.alarmId!, draft);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = ref.read(alarmControllerProvider).error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final output = ref.watch(outputControllerProvider);
    final playlists =
        ref
            .watch(playlistListProvider(const PlaylistListQuery()))
            .value
            ?.items ??
        const <Playlist>[];
    final targets = <String, String>{};
    for (final g in output.groups) {
      targets[g.id] = outputGroupLabel(g, output);
    }

    return AlertDialog(
      title: Text(widget.initial == null ? '新建闹钟' : '编辑闹钟'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称（可留空）',
                  hintText: '起床',
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('时间'),
                subtitle: Text(_draft.timeOfDay),
                trailing: const Icon(Icons.schedule),
                onTap: _pickTime,
              ),
              const SizedBox(height: 4),
              Text('重复', style: Theme.of(context).textTheme.labelLarge),
              Wrap(
                spacing: 6,
                children: [
                  for (var i = 0; i < 7; i++)
                    FilterChip(
                      label: Text(AlarmDays.labels[i]),
                      selected: AlarmDays.has(_draft.daysMask, i),
                      onSelected:
                          (_) => setState(
                            () =>
                                _draft = _draft.copyWith(
                                  daysMask: AlarmDays.toggle(
                                    _draft.daysMask,
                                    i,
                                  ),
                                ),
                          ),
                    ),
                ],
              ),
              Text(
                AlarmDays.describe(_draft.daysMask),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue:
                    targets.containsKey(_draft.targetId)
                        ? _draft.targetId
                        : null,
                decoration: const InputDecoration(labelText: '播放目标'),
                items: [
                  for (final e in targets.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged:
                    (v) => setState(
                      () => _draft = _draft.copyWith(targetId: v ?? ''),
                    ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue:
                    _draft.playlistId == 0 ||
                            !playlists.any((p) => p.id == _draft.playlistId)
                        ? 0
                        : _draft.playlistId,
                decoration: const InputDecoration(labelText: '起播歌单'),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('不播放（只调音量）')),
                  for (final p in playlists)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged:
                    (v) => setState(
                      () => _draft = _draft.copyWith(playlistId: v ?? 0),
                    ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('音量'),
                  Expanded(
                    child: Slider(
                      value: _draft.volume.toDouble().clamp(0, 100).toDouble(),
                      max: 100,
                      divisions: 20,
                      label: '${_draft.volume}',
                      onChanged:
                          (v) => setState(
                            () => _draft = _draft.copyWith(volume: v.round()),
                          ),
                    ),
                  ),
                  Text('${_draft.volume}'),
                ],
              ),
              Row(
                children: [
                  const Text('渐强'),
                  Expanded(
                    child: Slider(
                      value:
                          _draft.fadeSeconds
                              .toDouble()
                              .clamp(0, 120)
                              .toDouble(),
                      max: 120,
                      divisions: 24,
                      label: '${_draft.fadeSeconds}s',
                      onChanged:
                          (v) => setState(
                            () =>
                                _draft = _draft.copyWith(
                                  fadeSeconds: v.round(),
                                ),
                          ),
                    ),
                  ),
                  Text('${_draft.fadeSeconds}s'),
                ],
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.color,
    required this.onClose,
  });

  final String text;
  final Color color;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
      ],
    ),
  );
}
