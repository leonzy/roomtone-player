import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/utils/responsive_snackbar.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';

/// 新建同步组（F1）。
///
/// 候选设备里待机与离线的直接置灰：待机设备收不到帧、也不在同步环里，
/// 让它进组只会变成"配好了却不出声"。全组都能精确对齐时才是精确同步组；
/// 只要混进一台只能起播对齐的设备，整组就降级 —— 这一点在 UI 上提前讲明，
/// 免得用户建完才发现有回声。
Future<void> showCreateGroupSheet(BuildContext context, WidgetRef ref) async {
  final state = ref.read(outputControllerProvider);
  final controller = ref.read(outputControllerProvider.notifier);
  final candidates = state.candidatesFor('');
  final nameController = TextEditingController();
  final selected = <String>{};

  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) {
            final theme = Theme.of(ctx);
            final exactAll = selected.every(state.exactCapable);
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('新建同步组', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: '组名（可留空，默认用主控设备名）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (candidates.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '没有可加入的设备：设备需要在线且不处于待机。',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final d in candidates)
                            CheckboxListTile(
                              value: selected.contains(d.id),
                              onChanged:
                                  d.usable
                                      ? (v) => setLocal(() {
                                        if (v == true) {
                                          selected.add(d.id);
                                        } else {
                                          selected.remove(d.id);
                                        }
                                      })
                                      : null,
                              title: Text(d.displayName),
                              subtitle: Text(
                                [
                                  d.kind.label,
                                  d.caps.syncTier.label,
                                  if (d.standby) '待机',
                                  if (!d.online) '离线',
                                ].join(' · '),
                              ),
                              secondary: Icon(
                                d.kind == OutputKind.raop
                                    ? Icons.airplay
                                    : d.kind == OutputKind.dlna
                                    ? Icons.cast
                                    : Icons.phone_android,
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (selected.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        exactAll
                            ? '全部设备支持精确同步（RTP 时间戳对齐）。'
                            : '含只能起播对齐的设备：整组降级为「起播对齐」，可能有回声。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              exactAll
                                  ? theme.colorScheme.outline
                                  : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed:
                        selected.isEmpty
                            ? null
                            : () => Navigator.of(ctx).pop(true),
                    child: const Text('创建'),
                  ),
                ],
              ),
            );
          },
        ),
  );

  final name = nameController.text.trim();
  nameController.dispose();
  if (created != true || selected.isEmpty) return;

  final ok = await controller.createGroup(selected.toList(), name: name);
  if (!context.mounted) return;
  final s = ref.read(outputControllerProvider);
  if (ok) {
    ResponsiveSnackBar.showSuccess(context, message: '已创建同步组');
  } else if (s.error.isNotEmpty) {
    ResponsiveSnackBar.showError(context, message: s.error);
  }
}

/// 成员参数编辑（F1）：延迟补偿、音量偏移、主控切换、移出。
///
/// 延迟是"这台比别的设备慢多少"的补偿值，不是播放偏移；音量偏移是相对
/// 组基准的加减，实际值由服务端 clamp 到 0-100。
Future<void> showMemberSheet(
  BuildContext context,
  WidgetRef ref,
  OutputGroup group,
  String playerId,
) async {
  final state = ref.read(outputControllerProvider);
  final controller = ref.read(outputControllerProvider.notifier);
  final device = state.playerOf(playerId);
  final member = group.members.firstWhere(
    (m) => m.playerId == playerId,
    orElse: () => OutputMember(playerId: playerId),
  );
  var delay = member.delayMs.toDouble();
  var offset = member.volumeOffset.toDouble();

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) {
            final theme = Theme.of(ctx);
            final isMaster = group.masterId == playerId;
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    device?.displayName ?? playerId,
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    [
                      device?.kind.label ?? '',
                      isMaster ? '主控' : '成员',
                      if (device?.standby ?? false) '待机',
                    ].where((e) => e.isNotEmpty).join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Text('延迟补偿 ${delay.round()} ms'),
                  Slider(
                    value: delay.clamp(0, 500).toDouble(),
                    max: 500,
                    divisions: 50,
                    label: '${delay.round()} ms',
                    onChanged: (v) => setLocal(() => delay = v),
                  ),
                  Text(
                    '设备自身缓冲比别的设备大时，给它加延迟对齐。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '音量偏移 ${offset.round() > 0 ? '+' : ''}${offset.round()}',
                  ),
                  Slider(
                    value: offset.clamp(-20, 20).toDouble(),
                    min: -20,
                    max: 20,
                    divisions: 40,
                    label: '${offset.round()}',
                    onChanged: (v) => setLocal(() => offset = v),
                  ),
                  const SizedBox(height: 12),
                  _OrderRow(
                    group: group,
                    playerId: playerId,
                    onMove: (delta) async {
                      final ids = group.members.map((m) => m.playerId).toList();
                      final from = ids.indexOf(playerId);
                      final to = from + delta;
                      if (from < 0 || to < 0 || to >= ids.length) return;
                      ids.removeAt(from);
                      ids.insert(to, playerId);
                      final ok = await controller.reorderMembers(group.id, ids);
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (!context.mounted) return;
                      final s = ref.read(outputControllerProvider);
                      if (ok) {
                        ResponsiveSnackBar.showSuccess(
                          context,
                          message: '已调整成员顺序',
                        );
                      } else if (s.error.isNotEmpty) {
                        ResponsiveSnackBar.showError(context, message: s.error);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final ok = await controller.updateMember(
                        group.id,
                        playerId,
                        delayMs: delay.round(),
                        volumeOffset: offset.round(),
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (!context.mounted) return;
                      final s = ref.read(outputControllerProvider);
                      if (ok) {
                        ResponsiveSnackBar.showSuccess(
                          context,
                          message: '已更新成员参数',
                        );
                      } else if (s.error.isNotEmpty) {
                        ResponsiveSnackBar.showError(context, message: s.error);
                      }
                    },
                    child: const Text('保存'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (!isMaster)
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final ok = await controller.setMaster(
                                group.id,
                                playerId,
                              );
                              if (ctx.mounted) Navigator.of(ctx).pop();
                              if (!context.mounted) return;
                              final s = ref.read(outputControllerProvider);
                              if (ok) {
                                ResponsiveSnackBar.showSuccess(
                                  context,
                                  message: '已切换主控',
                                );
                              } else if (s.error.isNotEmpty) {
                                ResponsiveSnackBar.showError(
                                  context,
                                  message: s.error,
                                );
                              }
                            },
                            child: const Text('设为中控'),
                          ),
                        ),
                      if (!isMaster) const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final ok = await controller.removeMember(
                              group.id,
                              playerId,
                              mode: 'stop',
                            );
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            if (!context.mounted) return;
                            final s = ref.read(outputControllerProvider);
                            if (ok) {
                              ResponsiveSnackBar.showSuccess(
                                context,
                                message: '已移出并停止',
                              );
                            } else if (s.error.isNotEmpty) {
                              ResponsiveSnackBar.showError(
                                context,
                                message: s.error,
                              );
                            }
                          },
                          child: const Text('移出并停止'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
  );
}

/// 上移 / 下移：TV 上没有拖拽，这两个按钮是唯一可达的排序方式。
///
/// 顺序决定"主控候选"提示（主控本身是显式的，不会因为排序改变）。
class _OrderRow extends StatelessWidget {
  const _OrderRow({
    required this.group,
    required this.playerId,
    required this.onMove,
  });

  final OutputGroup group;
  final String playerId;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final ids = group.members.map((m) => m.playerId).toList();
    final index = ids.indexOf(playerId);
    return Row(
      children: [
        const Expanded(child: Text('顺序')),
        IconButton(
          tooltip: '上移',
          onPressed: index > 0 ? () => onMove(-1) : null,
          icon: const Icon(Icons.arrow_upward),
        ),
        IconButton(
          tooltip: '下移',
          onPressed:
              index >= 0 && index < ids.length - 1 ? () => onMove(1) : null,
          icon: const Icon(Icons.arrow_downward),
        ),
      ],
    );
  }
}
