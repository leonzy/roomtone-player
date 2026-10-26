import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../shared/utils/responsive_snackbar.dart';
import '../pages/group_editor.dart';
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

/// 区域控制台：列出全部区域，行内可直接传输与调音量。
///
/// 关键语义（docs/architecture_playback_ui.md §4.2）：
/// - 点行主体只切本地焦点，不发任何请求；
/// - 行内 ▶/⏸ 只控制该区域；
/// - 行内音量 300ms 防抖后提交该区域；
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
    final zones = buildZoneEntries(state);
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
                    '切换焦点不会改变播放',
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
  Timer? _volumeDebounce;
  late double _volume;
  int? _lastSentVolume;
  bool _dragging = false;
  bool _signalExpanded = false;

  @override
  void initState() {
    super.initState();
    _volume = widget.zone.volume.toDouble().clamp(0, 100).toDouble();
  }

  @override
  void didUpdateWidget(covariant _ZoneRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 服务端刷新回来的音量只在用户没有拖动、也没有待提交值时回填，
    // 否则滑杆会在拖动过程中被旧值拽回去。
    if (!_dragging &&
        _volumeDebounce == null &&
        widget.zone.volume != oldWidget.zone.volume) {
      _volume = widget.zone.volume.toDouble().clamp(0, 100).toDouble();
    }
    // 服务端回退到旧版本 / 区域被替换后 signal_path 可能消失，收起面板。
    if (widget.zone.signalPath == null) {
      _signalExpanded = false;
    }
  }

  @override
  void dispose() {
    _volumeDebounce?.cancel();
    super.dispose();
  }

  void _onVolumeChanged(double value) {
    setState(() => _volume = value);
    _volumeDebounce?.cancel();
    _volumeDebounce = Timer(const Duration(milliseconds: 300), () async {
      _volumeDebounce = null;
      final next = _volume.round().clamp(0, 100).toInt();
      if (next == _lastSentVolume) return;
      _lastSentVolume = next;
      final result = await ref
          .read(outputControllerProvider.notifier)
          .setZoneVolume(widget.zone.id, next);
      if (!mounted) return;
      // 失败时允许用户再次拖到同一值重试；成功时以服务端 clamp 后的值为准。
      _lastSentVolume = result?.volume;
    });
  }

  void _onVolumeChangeStart(double _) {
    _dragging = true;
  }

  void _onVolumeChangeEnd(double _) {
    _dragging = false;
  }

  Future<void> _toggleTransport() async {
    final zone = widget.zone;
    if (!zone.canControl) return;
    final action = zone.isPlaying ? 'pause' : 'play';
    final result = await ref
        .read(outputControllerProvider.notifier)
        .transport(zone.id, action);
    if (!mounted) return;
    if (result == null) {
      final error = ref.read(outputControllerProvider).error;
      if (error.isNotEmpty) {
        ResponsiveSnackBar.showError(context, message: error);
      }
    }
  }

  Future<void> _handleAction(_ZoneAction action) async {
    final zone = widget.zone;
    final state = ref.read(outputControllerProvider);
    final controller = ref.read(outputControllerProvider.notifier);
    final current = resolveFocusedZone(state, ref.read(zoneFocusProvider));

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
    final canControl = zone.canControl;
    final dimmed = !zone.online;
    final signalPath = zone.signalPath;

    return InkWell(
      key: ValueKey<String>('zone-row-body-${zone.id}'),
      onTap:
          (widget.transferring || widget.handingOver)
              ? null
              : () => ref.read(zoneFocusProvider.notifier).focus(zone.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.focused ? Icons.circle : Icons.circle_outlined,
                  size: 10,
                  color:
                      widget.focused
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Icon(
                  zoneIconFor(zone),
                  size: 20,
                  color: dimmed ? theme.colorScheme.outline : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    zone.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight:
                          widget.focused ? FontWeight.w600 : FontWeight.w500,
                      color: dimmed ? theme.colorScheme.outline : null,
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
                        () =>
                            setState(() => _signalExpanded = !_signalExpanded),
                  ),
                IconButton(
                  key: ValueKey<String>('zone-transport-${zone.id}'),
                  tooltip: zone.isPlaying ? '暂停' : '播放',
                  onPressed:
                      canControl && !widget.transferring && !widget.handingOver
                          ? _toggleTransport
                          : null,
                  icon: Icon(
                    zone.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded,
                    size: 28,
                  ),
                ),
                PopupMenuButton<_ZoneAction>(
                  key: ValueKey<String>('zone-menu-${zone.id}'),
                  enabled:
                      zone.isReal &&
                      !widget.transferring &&
                      !widget.handingOver,
                  tooltip: '更多',
                  onSelected: _handleAction,
                  itemBuilder: (context) {
                    final current = resolveFocusedZone(
                      ref.read(outputControllerProvider),
                      ref.read(zoneFocusProvider),
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
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Row(
                children: [
                  Expanded(child: ZoneStatusLine(zone: zone)),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.volume_up_rounded,
                    size: 16,
                    color: dimmed ? theme.colorScheme.outline : null,
                  ),
                  SizedBox(
                    width: 96,
                    child: Slider(
                      key: ValueKey<String>('zone-volume-${zone.id}'),
                      value: _volume.clamp(0, 100).toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      onChanged: canControl ? _onVolumeChanged : null,
                      onChangeStart: canControl ? _onVolumeChangeStart : null,
                      onChangeEnd: canControl ? _onVolumeChangeEnd : null,
                    ),
                  ),
                ],
              ),
            ),
            if (signalPath != null)
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child:
                    _signalExpanded
                        ? SignalPathPanel(
                          key: ValueKey<String>('zone-signal-panel-${zone.id}'),
                          path: signalPath,
                        )
                        : const SizedBox.shrink(),
              ),
          ],
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
