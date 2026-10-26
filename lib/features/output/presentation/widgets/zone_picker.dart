import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../shared/utils/responsive_snackbar.dart';
import '../pages/group_editor.dart';
import '../../../playback/presentation/providers/local_output_provider.dart';
import '../providers/output_provider.dart';
import '../providers/zone_focus_provider.dart';
import '../providers/zone_transfer_provider.dart';
import 'signal_path.dart';
import 'zone_display.dart';

/// 打开 Roon 式区域选择器。
Future<void> showZonePicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const ZonePickerSheet(),
  );
}

/// 区域选择器：只负责「选哪个区域」，不承载任何播放控制。
///
/// 布局对齐 Roon 的区域弹层：一行 = 图标 + 名称，选中行整行高亮；
/// 音量、播放状态、进度都在主播放面板上，这里不重复展示。
///
/// 关键语义（docs/architecture_playback_ui.md §4.2）：
/// - 点行只切本地焦点，不发任何请求；
/// - 切区域 = 切整个播放器（队列 + 当前曲 + 进度），见 §12；
/// - 转移 / 分组 / 改名 / 派对都是显式菜单动作。
class ZonePickerSheet extends ConsumerStatefulWidget {
  const ZonePickerSheet({super.key});

  @override
  ConsumerState<ZonePickerSheet> createState() => _ZonePickerSheetState();
}

class _ZonePickerSheetState extends ConsumerState<ZonePickerSheet> {
  @override
  void initState() {
    super.initState();
    // 打开时做一次静默全量对齐；只读 GET，不改变任何区域的播放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(outputControllerProvider.notifier).refresh(silent: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(outputControllerProvider);
    final focusId = ref.watch(zoneFocusProvider);
    final localDeviceId = ref.watch(localDeviceIdProvider);
    final zones = buildZoneEntries(state, localDeviceId: localDeviceId);
    final theme = Theme.of(context);

    final transfer = ref.watch(zoneTransferProvider);
    // 超时提示只弹一次；notifier 自己负责 5s 计时与 state 事件结束。
    ref.listen<ZoneTransferState>(zoneTransferProvider, (previous, next) {
      if (!next.timedOut || (previous?.timedOut ?? false)) return;
      ResponsiveSnackBar.showError(context, message: '切换超时，请检查设备');
      ref.read(zoneTransferProvider.notifier).clearTimedOut();
    });

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Text('区域', style: theme.textTheme.titleLarge),
                  const SizedBox(width: 8),
                  if (state.loading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const Spacer(),
                  Text(
                    '选择区域即切换播放器',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            if (state.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        state.error,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: zones.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final zone = zones[index];
                  return _ZoneRow(
                    key: ValueKey<String>('zone-row-${zone.id}'),
                    zone: zone,
                    state: state,
                    focused: isZoneFocused(zone, focusId),
                    transferring: transfer.to == zone.id,
                    handingOver: transfer.from == zone.id,
                  );
                },
              ),
            ),
            const Divider(height: 1),
            const _ZonePickerBottomActions(),
          ],
        ),
      ),
    );
  }
}

class _ZoneRow extends ConsumerStatefulWidget {
  const _ZoneRow({
    super.key,
    required this.zone,
    required this.state,
    required this.focused,
    this.transferring = false,
    this.handingOver = false,
  });

  final ZoneEntry zone;
  final OutputState state;
  final bool focused;

  /// 本行是转移目标：显示「正在切换…」并禁用交互。
  final bool transferring;

  /// 本行是转移源：显示「正在移交」并禁用交互。
  final bool handingOver;

  @override
  ConsumerState<_ZoneRow> createState() => _ZoneRowState();
}

class _ZoneRowState extends ConsumerState<_ZoneRow> {
  bool _signalExpanded = false;

  @override
  void didUpdateWidget(covariant _ZoneRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 服务端回退到旧版本 / 区域被替换后 signal_path 可能消失，收起面板。
    if (widget.zone.signalPath == null) {
      _signalExpanded = false;
    }
  }

  Future<void> _handleAction(_ZoneAction action) async {
    final zone = widget.zone;
    final state = ref.read(outputControllerProvider);
    final controller = ref.read(outputControllerProvider.notifier);
    final current = resolveFocusedZone(
      state,
      ref.read(zoneFocusProvider),
      localDeviceId: ref.read(localDeviceIdProvider),
    );

    switch (action) {
      case _ZoneAction.transfer:
        if (current == null || !current.isReal || current.id == zone.id) return;
        ref
            .read(zoneTransferProvider.notifier)
            .begin(from: current.id, to: zone.id);
        final ok = await controller.transfer(
          fromGroupId: current.id,
          toGroupId: zone.id,
        );
        if (!mounted) return;
        if (!ok) {
          ref.read(zoneTransferProvider.notifier).complete(zone.id);
          _showResult(false, '转移失败');
          return;
        }
        // 转移完成后焦点跟着走：面板里选中的区域从 A 变成 B，
        // 播放条也切到 B 的队列与进度（Roon 的转移语义）。
        await ref.read(zoneFocusProvider.notifier).focus(zone.id);
        if (!mounted) return;
        _showResult(true, '已转移到${zone.name}');
        return;
      case _ZoneAction.group:
        if (current == null || !current.isReal || current.id == zone.id) return;
        final ok = await controller.mergeGroups(
          fromGroupId: current.id,
          toGroupId: zone.id,
        );
        _showResult(ok, '已与${current.name}分组');
        return;
      case _ZoneAction.rename:
        await _showRenameDialog();
        return;
      case _ZoneAction.party:
        final party = state.party;
        if (party != null) {
          final ok = await controller.partyJoin(zone.id);
          _showResult(ok, '已加入派对');
        } else {
          final ids = <String>{zone.id};
          if (current != null && current.isReal && current.id != zone.id) {
            ids.add(current.id);
          }
          final ok = await controller.createParty(ids.toList());
          _showResult(ok, '已开启派对');
        }
        return;
    }
  }

  void _showResult(bool ok, String success) {
    if (!mounted) return;
    final state = ref.read(outputControllerProvider);
    if (ok) {
      ResponsiveSnackBar.showSuccess(context, message: success);
    } else if (state.error.isNotEmpty) {
      ResponsiveSnackBar.showError(context, message: state.error);
    }
  }

  Future<void> _showRenameDialog() async {
    final zone = widget.zone;
    final nameController = TextEditingController(text: zone.name);
    var icon = zone.icon;
    String? error;

    final identity = await showDialog<_ZoneIdentity>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setLocal) => AlertDialog(
                  title: const Text('重命名区域'),
                  content: SizedBox(
                    width: 360,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: nameController,
                          autofocus: true,
                          maxLength: 40,
                          decoration: InputDecoration(
                            labelText: '区域名称',
                            errorText: error,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('图标', style: Theme.of(ctx).textTheme.labelMedium),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _iconChoice(
                              ctx,
                              key: '',
                              iconData: Icons.auto_awesome,
                              selected: icon.isEmpty,
                              onSelected: () => setLocal(() => icon = ''),
                            ),
                            for (final entry in zoneIconKeys.entries)
                              _iconChoice(
                                ctx,
                                key: entry.key,
                                iconData: entry.value,
                                selected: icon == entry.key,
                                onSelected:
                                    () => setLocal(() => icon = entry.key),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final name = nameController.text.trim();
                        if (name.isEmpty || name.runes.length > 40) {
                          setLocal(() => error = '名称需为 1~40 个字符');
                          return;
                        }
                        Navigator.of(
                          ctx,
                        ).pop(_ZoneIdentity(name: name, icon: icon));
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
          ),
    );
    nameController.dispose();
    if (identity == null || !mounted) return;

    final ok = await ref
        .read(outputControllerProvider.notifier)
        .renameGroup(zone.id, name: identity.name, icon: identity.icon);
    _showResult(ok, '已更新区域');
  }

  Widget _iconChoice(
    BuildContext context, {
    required String key,
    required IconData iconData,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return Tooltip(
      message: key.isEmpty ? '默认' : key,
      child: FilterChip(
        label: Icon(iconData, size: 18),
        selected: selected,
        onSelected: (_) => onSelected(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final zone = widget.zone;
    final theme = Theme.of(context);
    final dimmed = !zone.online;
    final signalPath = zone.signalPath;

    final selectedBg = theme.colorScheme.primaryContainer;
    final selectedFg = theme.colorScheme.onPrimaryContainer;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: widget.focused ? selectedBg : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>('zone-row-body-${zone.id}'),
          onTap:
              (widget.transferring || widget.handingOver)
                  ? null
                  : () => ref.read(zoneFocusProvider.notifier).focus(zone.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      zoneIconFor(zone),
                      size: 26,
                      color:
                          dimmed
                              ? theme.colorScheme.outline
                              : widget.focused
                              ? selectedFg
                              : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        zone.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight:
                              widget.focused
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                          color:
                              dimmed
                                  ? theme.colorScheme.outline
                                  : widget.focused
                                  ? selectedFg
                                  : null,
                        ),
                      ),
                    ),
                    if (widget.transferring || widget.handingOver)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          widget.transferring ? '正在切换…' : '正在移交',
                          key: ValueKey<String>('zone-transfer-${zone.id}'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    if (signalPath != null)
                      SignalPathDot(
                        key: ValueKey<String>('zone-signal-${zone.id}'),
                        kind: signalPath.kind,
                        expanded: _signalExpanded,
                        onTap:
                            () => setState(
                              () => _signalExpanded = !_signalExpanded,
                            ),
                      ),
                    PopupMenuButton<_ZoneAction>(
                      key: ValueKey<String>('zone-menu-${zone.id}'),
                      enabled:
                          zone.isReal &&
                          !widget.transferring &&
                          !widget.handingOver,
                      tooltip: '更多',
                      padding: EdgeInsets.zero,
                      iconSize: 20,
                      onSelected: _handleAction,
                      itemBuilder: (context) {
                        final current = resolveFocusedZone(
                          ref.read(outputControllerProvider),
                          ref.read(zoneFocusProvider),
                          localDeviceId: ref.read(localDeviceIdProvider),
                        );
                        final canUseCurrent =
                            current != null &&
                            current.isReal &&
                            current.id != zone.id;
                        final inParty = zone.partyId.isNotEmpty;
                        return [
                          PopupMenuItem(
                            value: _ZoneAction.transfer,
                            enabled: canUseCurrent,
                            child: const Text('转移到此区域'),
                          ),
                          PopupMenuItem(
                            value: _ZoneAction.group,
                            enabled: canUseCurrent,
                            child: const Text('与当前区域分组'),
                          ),
                          const PopupMenuItem(
                            value: _ZoneAction.rename,
                            child: Text('重命名 / 图标'),
                          ),
                          PopupMenuItem(
                            value: _ZoneAction.party,
                            enabled: !inParty,
                            child: Text(inParty ? '已在派对中' : '加入派对'),
                          ),
                        ];
                      },
                    ),
                  ],
                ),
                if (signalPath != null)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child:
                        _signalExpanded
                            ? SignalPathPanel(
                              key: ValueKey<String>(
                                'zone-signal-panel-${zone.id}',
                              ),
                              path: signalPath,
                            )
                            : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZonePickerBottomActions extends ConsumerWidget {
  const _ZonePickerBottomActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () => showCreateGroupSheet(context, ref),
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建区域'),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () {
                final router = GoRouter.of(context);
                Navigator.of(context).pop();
                router.push(AppRoutes.output);
              },
              icon: const Icon(Icons.settings_rounded),
              label: const Text('音频设备设置'),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ZoneAction { transfer, group, rename, party }

class _ZoneIdentity {
  const _ZoneIdentity({required this.name, required this.icon});

  final String name;
  final String icon;
}
