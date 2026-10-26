import 'package:flutter/material.dart';

import '../../domain/output_models.dart';

/// 信号路径三色：绿=无损直通，紫=经 DSP，橙=有损转码。
///
/// 颜色是诊断语义，不跟随主题色：用户需要一眼分辨"声音有没有被处理"。
const Color signalPathLosslessColor = Color(0xFF2E7D32);
const Color signalPathEnhancedColor = Color(0xFF7B1FA2);
const Color signalPathLossyColor = Color(0xFFEF6C00);

/// 按后端 `signal_path.kind` 取指示点颜色。
Color signalPathColor(SignalPathKind kind) => switch (kind) {
  SignalPathKind.lossless => signalPathLosslessColor,
  SignalPathKind.enhanced => signalPathEnhancedColor,
  SignalPathKind.lossy => signalPathLossyColor,
};

/// 区域行右侧的三色指示点。
///
/// 只负责展示与点击回调；展开状态由调用方持有，避免和区域焦点状态耦合。
class SignalPathDot extends StatelessWidget {
  const SignalPathDot({
    super.key,
    required this.kind,
    this.expanded = false,
    this.onTap,
  });

  final SignalPathKind kind;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = signalPathColor(kind);
    final label = kind.label;
    return Tooltip(
      message: expanded ? '$label · 收起链路' : '$label · 查看链路',
      child: Semantics(
        button: true,
        label: '信号路径：$label',
        child: InkResponse(
          onTap: onTap,
          radius: 18,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: expanded ? 12 : 10,
                height: expanded ? 12 : 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: expanded ? 0.45 : 0.2),
                      blurRadius: expanded ? 6 : 2,
                      spreadRadius: expanded ? 2 : 0,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开后的五段链路面板：源 → 解码 → DSP → 输出 → 设备。
class SignalPathPanel extends StatelessWidget {
  const SignalPathPanel({super.key, required this.path});

  final SignalPath path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = signalPathColor(path.kind);
    return Container(
      margin: const EdgeInsets.only(left: 26, right: 8, top: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                path.kind.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (path.stages.isEmpty)
            Text(
              '暂无链路信息',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (var i = 0; i < path.stages.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              _SignalStageRow(index: i, stage: path.stages[i]),
            ],
        ],
      ),
    );
  }
}

class _SignalStageRow extends StatelessWidget {
  const _SignalStageRow({required this.index, required this.stage});

  final int index;
  final SignalStage stage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = stage.name.trim().isEmpty ? '第${index + 1}段' : stage.name;
    final detail = stage.detail.trim().isEmpty ? '—' : stage.detail;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 40,
          child: Text(
            name,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(detail, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}
