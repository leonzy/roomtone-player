import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/utils/responsive_snackbar.dart';
import '../../../../shared/widgets/browse_card.dart' show BrowseCardAction;
import '../providers/output_provider.dart';
import '../providers/zone_focus_provider.dart';
import '../widgets/zone_display.dart';

/// 解析当前焦点对应的真实组 id。
///
/// 焦点为空表示用户还没选区域；[kLocalZoneId] 是客户端哨兵，只有服务端
/// 已经为本机建好真实组时才能发队列命令。返回 null 时调用方应提示先选区域。
String? focusedRealGroupId(OutputState state, String? focusId) {
  if (focusId == null || focusId.isEmpty) return null;
  if (focusId != kLocalZoneId) return focusId;
  final zone = resolveFocusedZone(state, focusId);
  return zone != null && zone.isReal ? zone.id : null;
}

/// 把一首歌插到当前焦点区域的“下一首”。
///
/// 成功提示“已加入下一首”；没有焦点区域时只提示，不发请求。
Future<void> enqueueNextToFocusedZone(
  BuildContext context,
  WidgetRef ref,
  int songId,
) async {
  final groupId = focusedRealGroupId(
    ref.read(outputControllerProvider),
    ref.read(zoneFocusProvider),
  );
  if (groupId == null) {
    ResponsiveSnackBar.show(context, message: '请先选择播放区域');
    return;
  }

  final status = await ref.read(outputControllerProvider.notifier).enqueueNext(
    groupId,
    <int>[songId],
  );
  if (!context.mounted) return;

  if (status == null) {
    final error = ref.read(outputControllerProvider).error;
    ResponsiveSnackBar.showError(
      context,
      message: error.isNotEmpty ? error : '加入下一首失败',
    );
    return;
  }
  ResponsiveSnackBar.showSuccess(context, message: '已加入下一首');
}

/// 歌曲菜单里的“下一首播放”动作。
BrowseCardAction enqueueNextMenuAction({
  required BuildContext context,
  required WidgetRef ref,
  required int songId,
}) {
  return BrowseCardAction(
    value: 'enqueue_next',
    icon: Icons.queue_play_next,
    label: AppLocalizations.of(context).libraryPlayNext,
    onTap: () => enqueueNextToFocusedZone(context, ref, songId),
  );
}
