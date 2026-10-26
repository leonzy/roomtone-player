import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/features/playback/domain/playback_event.dart';

void main() {
  test('解析统一信封并保留 raw map', () {
    final event = PlaybackEvent.fromJson(<String, dynamic>{
      'seq': 7,
      'type': 'state',
      'time_ms': 123456,
      'group_id': 'g1',
      'song_id': 42,
      'position_ms': 9000,
      'status': 'playing',
      'future_field': 'kept',
    });

    expect(event.seq, 7);
    expect(event.type, 'state');
    expect(event.timeMs, 123456);
    expect(event.groupId, 'g1');
    expect(event.songId, 42);
    expect(event.positionMs, 9000);
    expect(event.status, 'playing');
    expect(event.raw['future_field'], 'kept');
    expect(() => event.raw['x'] = 1, throwsUnsupportedError);
  });

  test('tryParse 丢弃缺少 seq/type 或非 JSON 的消息', () {
    expect(PlaybackEvent.tryParse('not json'), isNull);
    expect(PlaybackEvent.tryParse('[]'), isNull);
    expect(PlaybackEvent.tryParse('{"type":"state"}'), isNull);
    expect(PlaybackEvent.tryParse('{"seq":1}'), isNull);

    final parsed = PlaybackEvent.tryParse(
      jsonEncode(<String, dynamic>{'seq': 1, 'type': 'error'}),
    );
    expect(parsed, isNotNull);
    expect(parsed!.seq, 1);
    expect(parsed.timeMs, 0);
  });

  test('兼容数字字符串与布尔字段', () {
    final event = PlaybackEvent.fromJson(<String, dynamic>{
      'seq': '9',
      'type': 'eq_changed',
      'time_ms': '100',
      'enabled': 'true',
      'corrected': 0,
      'offset_ms': '25',
    });

    expect(event.seq, 9);
    expect(event.timeMs, 100);
    expect(event.enabled, isTrue);
    expect(event.corrected, isFalse);
    expect(event.offsetMs, 25);
  });
}
