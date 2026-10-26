import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../shared/utils/responsive_snackbar.dart';
import '../../../output/domain/output_models.dart';
import '../../../output/presentation/providers/output_provider.dart';
import '../../../output/presentation/providers/zone_focus_provider.dart';

/// 本机播放器设置（F7-07）。
///
/// 入口：设置 → 播放与音箱 → 本机。
/// `takeover_behavior` 存在服务端 `players` 行（跟设备走，换手机不丢）；
/// 离线时用本地缓存值兜底，避免设置页显示成默认值。
class SpeakerSettingsPage extends ConsumerStatefulWidget {
  const SpeakerSettingsPage({super.key});

  @override
  ConsumerState<SpeakerSettingsPage> createState() =>
      _SpeakerSettingsPageState();
}

class _SpeakerSettingsPageState extends ConsumerState<SpeakerSettingsPage> {
  static const _cachePrefix = 'roomtone_takeover_';

  bool _loading = true;
  String _error = '';
  final Map<String, String> _cached = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final controller = ref.read(outputControllerProvider.notifier);
    await controller.refresh();
    if (!mounted) return;

    final state = ref.read(outputControllerProvider);
    final prefs = await SharedPreferences.getInstance();
    final cached = <String, String>{};
    for (final player in state.players.where(
      (p) => p.kind == OutputKind.local,
    )) {
      final value = prefs.getString('$_cachePrefix${player.id}');
      if (value != null && (value == 'pause' || value == 'follow')) {
        cached[player.id] = value;
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = state.error;
      _cached
        ..clear()
        ..addAll(cached);
    });
  }

  String _takeoverOf(OutputDevice player) {
    if (player.takeover == 'pause' || player.takeover == 'follow') {
      return player.takeover;
    }
    return _cached[player.id] ?? 'pause';
  }

  Future<void> _setTakeover(OutputDevice player, String value) async {
    final controller = ref.read(outputControllerProvider.notifier);
    final ok = await controller.setTakeover(player.id, value);
    if (!mounted) return;
    if (!ok) {
      final error = ref.read(outputControllerProvider).error;
      setState(() => _error = error);
      ResponsiveSnackBar.showError(context, message: error);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_cachePrefix${player.id}', value);
    if (!mounted) return;
    setState(() {
      _error = '';
      _cached[player.id] = value;
    });
    ResponsiveSnackBar.showSuccess(
      context,
      message: value == 'follow' ? '已改为静默跟随' : '已改为暂停本机',
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(outputControllerProvider);
    final autoFollow = ref.watch(zoneAutoFollowProvider);
    final locals = state.players
        .where((p) => p.kind == OutputKind.local)
        .toList(growable: false);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('本机'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body:
          _loading && locals.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                  children: [
                    if (_error.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _error,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: SwitchListTile(
                        secondary: const Icon(Icons.my_location),
                        title: const Text('开始播放时自动切换焦点'),
                        subtitle: const Text('在其他区域开始播放时，控制焦点自动跟随'),
                        value: autoFollow,
                        onChanged: (value) {
                          ref
                              .read(zoneAutoFollowProvider.notifier)
                              .setAutoFollow(value);
                        },
                      ),
                    ),
                    if (locals.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          children: [
                            Icon(
                              Icons.computer_outlined,
                              size: 48,
                              color: theme.colorScheme.outline,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '本机还没有注册为播放器',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '连接服务端后会自动注册；稍后下拉刷新。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    for (final player in locals)
                      _LocalPlayerCard(
                        player: player,
                        takeover: _takeoverOf(player),
                        busy: state.busy,
                        onChanged: (value) => _setTakeover(player, value),
                      ),
                  ],
                ),
              ),
    );
  }
}

class _LocalPlayerCard extends StatelessWidget {
  const _LocalPlayerCard({
    required this.player,
    required this.takeover,
    required this.busy,
    required this.onChanged,
  });

  final OutputDevice player;
  final String takeover;
  final bool busy;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.computer),
            title: Text(player.displayName),
            subtitle: Text(
              [
                '本机',
                player.online ? '在线' : '离线（显示本地缓存值）',
                if (player.id.isNotEmpty) player.id,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('被其他设备接管时', style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '本机正在播放时，另一台设备把区域切走：暂停会立即停下并提示，'
              '跟随则静默转为纯控制器。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          RadioGroup<String>(
            groupValue: takeover,
            onChanged: (value) {
              if (busy) return;
              if (value != null && value != takeover) onChanged(value);
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  value: 'pause',
                  enabled: !busy,
                  title: const Text('暂停本机'),
                  subtitle: const Text('默认；立即暂停并弹出非阻塞提示'),
                ),
                RadioListTile<String>(
                  value: 'follow',
                  enabled: !busy,
                  title: const Text('静默跟随'),
                  subtitle: const Text('不暂停，转为纯控制器，不弹提示'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
