import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/utils/responsive_snackbar.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';
import '../widgets/zone_display.dart';

/// 派对面板（F4）。
///
/// 派对和同步组是两层：组内用精确时钟对齐，派对只负责把多个组的播放进度
/// 拉到 leader 组附近。几个必须体现在 UI 上的事实：
///
/// - 每个成员组各自解码，各占一个解码槽位；槽位不够时创建会失败，必须
///   把服务端错误原样展示。
/// - 偏差超过 `party_drift_tolerance_ms` 只是标记 `drifting`，连续校正失败
///   才是 `unaligned`（已放弃重试）。两者都只做静态标记，不弹窗。
/// - 退出成员组有 continue / stop 两种模式，默认 continue（本地继续播）。
class PartySheet extends ConsumerStatefulWidget {
  const PartySheet({super.key});

  @override
  ConsumerState<PartySheet> createState() => _PartySheetState();
}

class _PartySheetState extends ConsumerState<PartySheet> {
  final _selected = <String>{};
  final _nameCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_selected.isEmpty) {
      ResponsiveSnackBar.showError(context, message: '至少选择一个组');
      return;
    }
    setState(() => _submitting = true);
    final ok = await ref
        .read(outputControllerProvider.notifier)
        .createParty(_selected.toList(), name: _nameCtrl.text.trim());
    if (!mounted) return;
    setState(() => _submitting = false);
    final s = ref.read(outputControllerProvider);
    if (!ok && s.error.isNotEmpty) {
      ResponsiveSnackBar.showError(context, message: s.error);
    }
  }

  Future<void> _run(Future<bool> future, {String? success}) async {
    setState(() => _submitting = true);
    final ok = await future;
    if (!mounted) return;
    setState(() => _submitting = false);
    final s = ref.read(outputControllerProvider);
    if (ok) {
      if (success != null) {
        ResponsiveSnackBar.showSuccess(context, message: success);
      }
    } else if (s.error.isNotEmpty) {
      ResponsiveSnackBar.showError(context, message: s.error);
    }
  }

  String _groupName(List<OutputGroup> groups, String id) {
    for (final g in groups) {
      if (g.id == id) {
        return outputGroupLabel(g, ref.read(outputControllerProvider));
      }
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(outputControllerProvider);
    final theme = Theme.of(context);
    final party = state.party;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child:
            party == null
                ? _buildCreate(context, theme, state)
                : _buildManage(context, theme, state, party),
      ),
    );
  }

  Widget _buildCreate(
    BuildContext context,
    ThemeData theme,
    OutputState state,
  ) {
    final candidates = state.groups
        .where((g) => g.partyId.isEmpty)
        .toList(growable: false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('开启派对', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '派对把多个组的播放进度对齐到主控组。每个组独立解码、各占一个解码槽位。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: '派对名称（可留空）',
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        if (candidates.isEmpty)
          Text('没有可加入的组：先在设备页建一个同步组。', style: theme.textTheme.bodySmall)
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children:
                  candidates
                      .map(
                        (g) => CheckboxListTile(
                          value: _selected.contains(g.id),
                          onChanged:
                              (v) => setState(() {
                                if (v == true) {
                                  _selected.add(g.id);
                                } else {
                                  _selected.remove(g.id);
                                }
                              }),
                          title: Text(outputGroupLabel(g, state)),
                          subtitle: Text(
                            '${g.members.length} 台设备'
                            '${g.isPlaying ? ' · 播放中' : ''}'
                            '${g.hasOfflineMember ? ' · 含离线设备' : ''}',
                          ),
                          dense: true,
                        ),
                      )
                      .toList(),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _submitting || candidates.isEmpty ? null : _create,
          child: Text(_submitting ? '创建中…' : '开启派对'),
        ),
      ],
    );
  }

  Widget _buildManage(
    BuildContext context,
    ThemeData theme,
    OutputState state,
    PartyStatus party,
  ) {
    final groups = state.groups;
    final members =
        party.members.isEmpty
            ? party.groups
                .map((id) => PartyMember(groupId: id))
                .toList(growable: false)
            : party.members;
    final joinable = groups
        .where((g) => g.partyId.isEmpty && !party.groups.contains(g.id))
        .toList(growable: false);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                party.name.isEmpty ? '派对' : party.name,
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: '播放',
              onPressed:
                  _submitting
                      ? null
                      : () => _run(
                        ref
                            .read(outputControllerProvider.notifier)
                            .partyTransport('play'),
                      ),
              icon: const Icon(Icons.play_arrow),
            ),
            IconButton(
              tooltip: '暂停',
              onPressed:
                  _submitting
                      ? null
                      : () => _run(
                        ref
                            .read(outputControllerProvider.notifier)
                            .partyTransport('pause'),
                      ),
              icon: const Icon(Icons.pause),
            ),
            IconButton(
              tooltip: '停止',
              onPressed:
                  _submitting
                      ? null
                      : () => _run(
                        ref
                            .read(outputControllerProvider.notifier)
                            .partyTransport('stop'),
                      ),
              icon: const Icon(Icons.stop),
            ),
          ],
        ),
        Text(
          '主控组：${_groupName(groups, party.leaderGroupId)}'
          '${party.hasDrift ? ' · 有组未对齐' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              ...members.map((m) {
                final inParty = party.groups.contains(m.groupId);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          _groupName(groups, m.groupId),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (m.groupId == party.leaderGroupId)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: _Tag(text: '主控'),
                        ),
                      if (m.unaligned)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: _Tag(text: '未对齐', warn: true),
                        )
                      else if (m.drifting)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: _Tag(text: '偏差偏大', warn: true),
                        ),
                    ],
                  ),
                  subtitle: Text(
                    '${_stateLabel(m.state)} · 偏移 ${m.offsetMs} ms',
                  ),
                  trailing:
                      inParty
                          ? PopupMenuButton<String>(
                            enabled: !_submitting,
                            onSelected:
                                (mode) => _run(
                                  ref
                                      .read(outputControllerProvider.notifier)
                                      .partyLeave(m.groupId, mode: mode),
                                  success:
                                      mode == 'stop' ? '已退出并停止' : '已退出，本地继续播放',
                                ),
                            itemBuilder:
                                (_) => const [
                                  PopupMenuItem(
                                    value: 'continue',
                                    child: Text('退出（继续播）'),
                                  ),
                                  PopupMenuItem(
                                    value: 'stop',
                                    child: Text('退出并停止'),
                                  ),
                                ],
                          )
                          : TextButton(
                            onPressed:
                                _submitting
                                    ? null
                                    : () => _run(
                                      ref
                                          .read(
                                            outputControllerProvider.notifier,
                                          )
                                          .partyJoin(m.groupId),
                                      success: '已加入派对',
                                    ),
                            child: const Text('加入'),
                          ),
                );
              }),
              if (joinable.isNotEmpty) ...[
                const Divider(height: 24),
                Text('未加入的组', style: theme.textTheme.labelLarge),
                ...joinable.map(
                  (g) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(outputGroupLabel(g, state)),
                    subtitle: Text('${g.members.length} 台设备'),
                    trailing: TextButton(
                      onPressed:
                          _submitting
                              ? null
                              : () => _run(
                                ref
                                    .read(outputControllerProvider.notifier)
                                    .partyJoin(g.id),
                                success: '已加入派对',
                              ),
                      child: const Text('加入'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed:
              _submitting
                  ? null
                  : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder:
                          (ctx) => AlertDialog(
                            title: const Text('结束派对'),
                            content: const Text('所有成员组停止同步，播放状态保持不变。'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('结束'),
                              ),
                            ],
                          ),
                    );
                    if (ok != true) return;
                    if (!context.mounted) return;
                    await _run(
                      ref.read(outputControllerProvider.notifier).endParty(),
                      success: '派对已结束',
                    );
                    if (context.mounted) Navigator.maybePop(context);
                  },
          icon: const Icon(Icons.exit_to_app),
          label: const Text('结束派对'),
        ),
      ],
    );
  }

  String _stateLabel(String state) => switch (state) {
    PlayState.playing => '播放中',
    PlayState.paused => '已暂停',
    PlayState.buffering => '缓冲中',
    PlayState.error => '出错',
    _ => '空闲',
  };
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: (warn ? scheme.errorContainer : scheme.secondaryContainer),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: warn ? scheme.onErrorContainer : scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// 从输出页顶部打开派对面板。创建与已开启状态共用一个面板。
Future<void> showPartySheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder:
        (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.92,
          builder: (_, _) => const PartySheet(),
        ),
  );
}
