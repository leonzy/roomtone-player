import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/utils/responsive_snackbar.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';
import '../../../alarms/presentation/pages/alarms_page.dart';
import '../widgets/power_toggle.dart';
import 'playback_tuning_sheet.dart';
import 'eq_sheet.dart';
import 'group_editor.dart';
import 'metrics_sheet.dart';
import 'party_sheet.dart';
import 'transfer_sheet.dart';

/// 播放输出面板（F0）：设备列表 + 组归属 + 待机/音量/发现。
///
/// 数据只有两条来源：`GET /playback`（组与状态）和 `GET /players`（设备能力）。
/// 页面可见时按 4s 轮询，离开即停；不做本地增量 diff —— 删组后组 id 会被
/// 换成带时间戳的新 id，本地 diff 会把新组当旧组。
class OutputPage extends ConsumerStatefulWidget {
  const OutputPage({super.key});

  @override
  ConsumerState<OutputPage> createState() => _OutputPageState();
}

class _OutputPageState extends ConsumerState<OutputPage> {
  @override
  void initState() {
    super.initState();
    // 首帧之后才能读 provider（build 里已有一轮全量对齐，这里只开轮询）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(outputControllerProvider.notifier).startPolling();
    });
  }

  @override
  void dispose() {
    ref.read(outputControllerProvider.notifier).stopPolling();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ResponsiveSnackBar.show(context, message: message);
  }

  Future<void> _discover() async {
    final ok = await ref.read(outputControllerProvider.notifier).discover();
    final s = ref.read(outputControllerProvider);
    _toast(ok ? (s.notice.isEmpty ? '扫描完成' : s.notice) : s.error);
  }

  Future<void> _addDevice() async {
    final address = TextEditingController();
    final deviceId = TextEditingController();
    final name = TextEditingController();
    var kind = OutputKind.dlna;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setLocal) => AlertDialog(
                  title: const Text('手动添加设备'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SegmentedButton<OutputKind>(
                          segments: const [
                            ButtonSegment(
                              value: OutputKind.dlna,
                              label: Text('DLNA'),
                            ),
                            ButtonSegment(
                              value: OutputKind.raop,
                              label: Text('AirPlay'),
                            ),
                          ],
                          selected: {kind},
                          onSelectionChanged:
                              (v) => setLocal(() => kind = v.first),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: address,
                          decoration: const InputDecoration(
                            labelText: '地址',
                            hintText: 'DLNA 可填 IP / host:port / desc.xml 地址',
                          ),
                        ),
                        if (kind == OutputKind.raop)
                          TextField(
                            controller: deviceId,
                            decoration: const InputDecoration(
                              labelText: 'device_id（MAC）',
                              hintText: 'AirPlay 的 RTSP 路径需要',
                            ),
                          ),
                        TextField(
                          controller: name,
                          decoration: const InputDecoration(
                            labelText: '名称（可留空）',
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('添加'),
                    ),
                  ],
                ),
          ),
    );
    final addr = address.text.trim();
    final did = deviceId.text.trim();
    final nm = name.text.trim();
    address.dispose();
    deviceId.dispose();
    name.dispose();
    if (confirmed != true || addr.isEmpty) return;
    final ok = await ref
        .read(outputControllerProvider.notifier)
        .addPlayer(address: addr, kind: kind, name: nm, deviceId: did);
    final s = ref.read(outputControllerProvider);
    _toast(ok ? '已添加设备' : s.error);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(outputControllerProvider);
    final controller = ref.read(outputControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('播放输出'),
        actions: [
          IconButton(
            tooltip: '新建同步组',
            onPressed:
                state.busy ? null : () => showCreateGroupSheet(context, ref),
            icon: const Icon(Icons.speaker_group_outlined),
          ),
          IconButton(
            tooltip: state.party == null ? '开启派对' : '派对中',
            onPressed: state.busy ? null : () => showPartySheet(context),
            icon: Icon(
              state.party == null
                  ? Icons.celebration_outlined
                  : Icons.celebration,
            ),
          ),
          IconButton(
            tooltip: '扫描音箱',
            onPressed: state.busy ? null : _discover,
            icon: const Icon(Icons.wifi_find_outlined),
          ),
          IconButton(
            tooltip: '播放调音（交叉淡化 / 响度均衡）',
            onPressed: () => showPlaybackTuningSheet(context),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: '闹钟',
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const AlarmsPage()),
                ),
            icon: const Icon(Icons.alarm),
          ),
          IconButton(
            tooltip: '运行指标',
            onPressed: () => showMetricsSheet(context),
            icon: const Icon(Icons.monitor_heart_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => controller.refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.busy ? null : _addDevice,
        icon: const Icon(Icons.add),
        label: const Text('添加设备'),
      ),
      body:
          state.players.isEmpty && state.loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: () => controller.refresh(),
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
                    if (state.players.isEmpty) _emptyHint(theme),
                    ..._buildGroups(state),
                    _OrphanDevices(state: state),
                  ],
                ),
              ),
    );
  }

  Widget _emptyHint(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Icon(
          Icons.speaker_outlined,
          size: 48,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text('还没有可用的输出设备', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          '点右上角扫描 AirPlay / DLNA 音箱，或手动添加地址',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  /// 按组渲染。单机组（只有自己）标题用"单机播放"，
  /// 免得用户以为那是自己配过的同步组。
  List<Widget> _buildGroups(OutputState state) {
    final controller = ref.read(outputControllerProvider.notifier);
    return [
      for (final group in state.groups)
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  group.isSolo ? Icons.speaker : Icons.speaker_group,
                ),
                title: Text(group.isSolo ? '单机播放' : group.name),
                subtitle: Text(_groupSubtitle(group)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (group.syncTier == SyncTier.aligned)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Chip(
                          label: Text('起播对齐'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    if (group.status.isActive)
                      IconButton(
                        tooltip: '转移播放',
                        onPressed:
                            state.busy
                                ? null
                                : () => showTransferSheet(context, ref, group),
                        icon: const Icon(Icons.multiple_stop),
                      ),
                    if (!group.isSolo)
                      IconButton(
                        tooltip: '解散同步组',
                        onPressed:
                            state.busy
                                ? null
                                : () async {
                                  final ok = await controller.deleteGroup(
                                    group.id,
                                  );
                                  final s = ref.read(outputControllerProvider);
                                  _toast(ok ? '已解散同步组' : s.error);
                                },
                        icon: const Icon(Icons.link_off),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              for (final m in group.members)
                _DeviceRow(
                  playerId: m.playerId,
                  group: group,
                  state: state,
                  onTap: () => showMemberSheet(context, ref, group, m.playerId),
                ),
            ],
          ),
        ),
    ];
  }

  String _groupSubtitle(OutputGroup group) {
    final status = group.status;
    final parts = <String>[];
    if (status.isPlaying) {
      parts.add('播放中 ${_fmtTime(status.position)}');
    } else if (status.isBuffering) {
      parts.add('缓冲中');
    } else if (status.state == PlayState.paused) {
      parts.add('已暂停 ${_fmtTime(status.position)}');
    } else {
      parts.add('空闲');
    }
    if (!group.isSolo) parts.add('${group.members.length} 台');
    if (group.hasOfflineMember) parts.add('含离线设备');
    if (group.partyId.isNotEmpty) parts.add('派对中');
    if (status.underruns > 0) parts.add('欠载 ${status.underruns}');
    return parts.join(' · ');
  }
}

String _fmtTime(double seconds) {
  final s = seconds.isFinite && seconds > 0 ? seconds.toInt() : 0;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// 设备行：名字、类型、同步等级、音量、待机开关、更多菜单。
class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({
    required this.playerId,
    required this.group,
    required this.state,
    required this.onTap,
  });

  final String playerId;
  final OutputGroup group;
  final OutputState state;

  /// 点行打开成员参数（延迟补偿 / 音量偏移 / 主控 / 移出）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final device = state.playerOf(playerId);
    final controller = ref.read(outputControllerProvider.notifier);
    final member = group.members.firstWhere(
      (m) => m.playerId == playerId,
      orElse: () => OutputMember(playerId: playerId),
    );
    final name = device?.displayName ?? playerId;
    final offline = device == null || !device.online;

    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(switch (device?.kind) {
        OutputKind.raop => Icons.airplay,
        OutputKind.dlna => Icons.cast,
        _ => Icons.phone_android,
      }, color: offline ? theme.colorScheme.outline : null),
      title: Row(
        children: [
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
          if (device != null) ...[
            const SizedBox(width: 6),
            Text(
              device.kind.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
          if (offline) ...[
            const SizedBox(width: 6),
            Text(
              '离线',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        _subtitle(member, device),
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (device != null && device.caps.supportsVolume)
            SizedBox(
              width: 120,
              child: Slider(
                value: device.volume.clamp(0, 100).toDouble(),
                max: 100,
                divisions: 20,
                label: '${device.volume}',
                onChanged:
                    offline
                        ? null
                        : (v) => controller.setVolume(
                          device.id,
                          v.round(),
                          muted: device.muted,
                        ),
              ),
            ),
          if (device != null)
            PowerToggle(
              device: device,
              busy: state.busy,
              onChanged: (on) async {
                final ok = await controller.setPower(device.id, on: on);
                final s = ref.read(outputControllerProvider);
                if (!ok && s.error.isNotEmpty && context.mounted) {
                  ResponsiveSnackBar.showError(context, message: s.error);
                }
              },
            ),
          if (device != null)
            PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'rename':
                    await _renameDevice(context, ref, device);
                  case 'reconnect':
                    await controller.reconnectPlayer(device.id);
                  case 'eq':
                    await showEqSheet(context, ref, device.id);
                  case 'remove':
                    await controller.removeMember(group.id, device.id);
                  case 'delete':
                    await controller.deletePlayer(device.id);
                }
              },
              itemBuilder:
                  (ctx) => [
                    const PopupMenuItem(value: 'rename', child: Text('重命名')),
                    const PopupMenuItem(
                      value: 'reconnect',
                      child: Text('重新连接'),
                    ),
                    const PopupMenuItem(value: 'eq', child: Text('均衡器')),
                    if (!group.isSolo)
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('移出同步组'),
                      ),
                    const PopupMenuItem(value: 'delete', child: Text('删除设备')),
                  ],
            ),
        ],
      ),
    );
  }

  String _subtitle(OutputMember member, OutputDevice? device) {
    final parts = <String>[];
    if (group.masterId == playerId) parts.add('主控');
    parts.add(
      (device?.caps.syncTier ?? SyncTier.exact) == SyncTier.exact
          ? '精确同步'
          : '起播对齐',
    );
    if (group.memberCaps.any((c) => c.playerId == playerId && c.syncing)) {
      parts.add('对齐中');
    }
    if (member.delayMs != 0) parts.add('延迟 ${member.delayMs}ms');
    if (member.volumeOffset != 0) parts.add('音量偏移 ${member.volumeOffset}');
    if (device != null && device.caps.needsPassword) parts.add('需要密码');
    return parts.join(' · ');
  }

  Future<void> _renameDevice(
    BuildContext context,
    WidgetRef ref,
    OutputDevice device,
  ) async {
    final controller = TextEditingController(text: device.name);
    final name = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('重命名设备'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称'),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == device.name) return;
    await ref
        .read(outputControllerProvider.notifier)
        .renamePlayer(device.id, name);
  }
}

/// 不在任何组里的设备（正常不该出现：单机组也算组，这里只兜底异常数据）。
class _OrphanDevices extends StatelessWidget {
  const _OrphanDevices({required this.state});

  final OutputState state;

  @override
  Widget build(BuildContext context) {
    final inGroup = <String>{};
    for (final g in state.groups) {
      inGroup.addAll(g.memberIds);
    }
    final orphans = state.players
        .where((p) => !inGroup.contains(p.id))
        .toList(growable: false);
    if (orphans.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('未加入组的设备'),
            subtitle: Text(
              '通常是刚发现还没建组，或组数据异常。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final p in orphans)
            ListTile(
              dense: true,
              title: Text(p.displayName),
              subtitle: Text('${p.kind.label} · ${p.address}'),
            ),
        ],
      ),
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
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Expanded(child: Text(text)),
        IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
      ],
    ),
  );
}
