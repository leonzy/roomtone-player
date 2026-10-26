import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/signal_path.dart';

SignalPath _path(SignalPathKind kind) => SignalPath(
  kind: kind,
  stages: const <SignalStage>[
    SignalStage(name: '源', detail: 'FLAC 44.1kHz'),
    SignalStage(name: '解码', detail: 'ffmpeg'),
    SignalStage(name: 'DSP', detail: 'EQ: rock'),
    SignalStage(name: '输出', detail: 'L16 44.1kHz/16bit'),
    SignalStage(name: '设备', detail: '客厅 Soundbar'),
  ],
);

Widget _panel(SignalPath path) =>
    MaterialApp(home: Scaffold(body: SignalPathPanel(path: path)));

void main() {
  test('三种 kind 的颜色映射', () {
    expect(signalPathColor(SignalPathKind.lossless), signalPathLosslessColor);
    expect(signalPathColor(SignalPathKind.enhanced), signalPathEnhancedColor);
    expect(signalPathColor(SignalPathKind.lossy), signalPathLossyColor);

    // 绿 / 紫 / 橙：颜色本身是诊断语义，不能随主题漂移。
    expect(signalPathLosslessColor, const Color(0xFF2E7D32));
    expect(signalPathEnhancedColor, const Color(0xFF7B1FA2));
    expect(signalPathLossyColor, const Color(0xFFEF6C00));

    expect(SignalPathKind.lossless.label, '无损直通');
    expect(SignalPathKind.enhanced.label, '经 DSP');
    expect(SignalPathKind.lossy.label, '有损转码');
  });

  testWidgets('展开面板显示五段 name + detail', (tester) async {
    await tester.pumpWidget(_panel(_path(SignalPathKind.enhanced)));

    for (final text in <String>[
      '源',
      '解码',
      'DSP',
      '输出',
      '设备',
      'FLAC 44.1kHz',
      'ffmpeg',
      'EQ: rock',
      'L16 44.1kHz/16bit',
      '客厅 Soundbar',
    ]) {
      expect(find.text(text), findsOneWidget, reason: '缺少链路文本：$text');
    }
  });

  testWidgets('缺失 stages 时显示占位且不崩', (tester) async {
    await tester.pumpWidget(
      _panel(const SignalPath(kind: SignalPathKind.lossy)),
    );

    expect(find.text('有损转码'), findsOneWidget);
    expect(find.text('暂无链路信息'), findsOneWidget);
  });

  test('signal_path 缺失 / 类型异常不崩', () {
    final legacy = OutputGroup.fromJson(<String, dynamic>{'id': 'g1'});
    expect(legacy.signalPath, isNull);

    final wrongType = OutputGroup.fromJson(<String, dynamic>{
      'id': 'g1',
      'signal_path': 'oops',
    });
    expect(wrongType.signalPath, isNull);

    final unknownKind = OutputGroup.fromJson(<String, dynamic>{
      'id': 'g1',
      'signal_path': <String, dynamic>{'kind': 'future'},
    });
    expect(unknownKind.signalPath, isNull);

    final partial = OutputGroup.fromJson(<String, dynamic>{
      'id': 'g1',
      'signal_path': <String, dynamic>{
        'kind': 'lossy',
        'stages': <dynamic>[
          <String, dynamic>{'name': '源'},
          null,
          <String, dynamic>{'detail': 'ffmpeg'},
        ],
      },
    });
    expect(partial.signalPath?.kind, SignalPathKind.lossy);
    expect(partial.signalPath?.stages.length, 2);
    expect(partial.signalPath?.stages.first.name, '源');
    expect(partial.signalPath?.stages.first.detail, '');
    expect(partial.signalPath?.stages.last.name, '');
    expect(partial.signalPath?.stages.last.detail, 'ffmpeg');
  });
}
