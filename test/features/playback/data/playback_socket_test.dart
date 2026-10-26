import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/features/playback/data/playback_socket.dart';
import 'package:songloft_flutter/features/playback/domain/playback_event.dart';

class _FakeConnection implements PlaybackConnection {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String payload) => sent.add(payload);

  void add(String payload) => _controller.add(payload);

  Future<void> finish() async {
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

class _FakeConnector implements PlaybackConnector {
  int attempts = 0;
  int failAttempts = 0;
  int failOpens = 0;
  int playbackCalls = 0;
  final List<String> tickets = <String>[];
  final List<String> openedTickets = <String>[];
  final List<_FakeConnection> connections = <_FakeConnection>[];

  @override
  Future<String> fetchTicket() async {
    attempts++;
    if (failAttempts > 0) {
      failAttempts--;
      throw Exception('offline');
    }
    final ticket = 'ticket-$attempts';
    tickets.add(ticket);
    return ticket;
  }

  @override
  Future<PlaybackConnection> openEvents(String ticket) async {
    if (failOpens > 0) {
      failOpens--;
      throw Exception('offline');
    }
    openedTickets.add(ticket);
    final connection = _FakeConnection();
    connections.add(connection);
    return connection;
  }

  @override
  Future<Map<String, dynamic>> fetchPlayback() async {
    playbackCalls++;
    return <String, dynamic>{
      'groups': <dynamic>[
        <String, dynamic>{'id': 'g1', 'status': 'playing'},
      ],
    };
  }
}

String _event(int seq, {String type = 'state'}) => jsonEncode(<String, dynamic>{
  'seq': seq,
  'type': type,
  'time_ms': seq * 10,
  'group_id': 'g1',
});

void main() {
  test('先换 ticket 再连 WS，并按 seq 去重', () async {
    final connector = _FakeConnector();
    final socket = PlaybackSocket(connector: connector);
    final received = <PlaybackEvent>[];
    final subscription = socket.events.listen(received.add);

    socket.connect();
    await pumpEventQueue();

    expect(connector.tickets, <String>['ticket-1']);
    expect(connector.openedTickets, <String>['ticket-1']);
    expect(connector.connections, hasLength(1));

    final connection = connector.connections.single;
    connection.add(_event(5));
    connection.add(_event(3));
    connection.add(_event(6, type: 'member_changed'));
    await pumpEventQueue();

    expect(received.map((e) => e.seq), <int>[5, 6]);
    expect(received.last.type, 'member_changed');
    expect(socket.lastSeq, 6);

    await subscription.cancel();
    await socket.dispose();
  });

  test('退避序列 1/2/4/8/16/30 秒封顶', () {
    fakeAsync((async) {
      final connector = _FakeConnector()..failAttempts = 100;
      final socket = PlaybackSocket(connector: connector);

      socket.connect();
      async.flushMicrotasks();
      expect(connector.attempts, 1);

      final attemptTimes = <Duration>[async.elapsed];
      for (final seconds in <int>[1, 2, 4, 8, 16, 30, 30]) {
        async.elapse(Duration(seconds: seconds));
        attemptTimes.add(async.elapsed);
        expect(connector.attempts, attemptTimes.length);
      }

      final gaps = <Duration>[
        for (var i = 1; i < attemptTimes.length; i++)
          attemptTimes[i] - attemptTimes[i - 1],
      ];
      expect(gaps, const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
        Duration(seconds: 30),
        Duration(seconds: 30),
      ]);

      unawaited(socket.dispose());
      async.flushMicrotasks();
    });
  });

  test('WS 握手失败同样计入连续失败', () {
    fakeAsync((async) {
      final connector = _FakeConnector()..failOpens = 3;
      final socket = PlaybackSocket(connector: connector);

      socket.connect();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.elapse(const Duration(seconds: 2));

      expect(connector.attempts, 3);
      expect(connector.connections, isEmpty);
      expect(socket.degraded.value, isTrue);

      unawaited(socket.dispose());
      async.flushMicrotasks();
    });
  });

  test('连续 3 次失败进入降级，每 3 秒轮询，重连后恢复', () {
    fakeAsync((async) {
      final connector = _FakeConnector()..failAttempts = 4;
      final socket = PlaybackSocket(connector: connector);

      socket.connect();
      async.flushMicrotasks();
      expect(socket.degraded.value, isFalse);

      async.elapse(const Duration(seconds: 1));
      async.elapse(const Duration(seconds: 2));
      expect(connector.attempts, 3);
      expect(socket.degraded.value, isTrue);

      // 第 3 次失败后开始 3 秒轮询；第 4 次重连在 t=7s 失败。
      async.elapse(const Duration(seconds: 3));
      expect(connector.playbackCalls, 1);
      async.elapse(const Duration(seconds: 3));
      expect(connector.playbackCalls, 2);
      async.elapse(const Duration(seconds: 3));
      expect(connector.playbackCalls, 3);

      // t=15s：第 5 次尝试成功，降级解除并立即拉一次全量对齐。
      async.elapse(const Duration(seconds: 3));
      expect(connector.attempts, 5);
      expect(connector.connections, hasLength(1));
      expect(socket.degraded.value, isFalse);
      // t=15s 时降级轮询与重连退避可能同时到期，因此只要求至少包含
      // 3 次轮询 + 1 次重连全量对齐。
      final callsAfterRecovery = connector.playbackCalls;
      expect(callsAfterRecovery, greaterThanOrEqualTo(4));
      expect(socket.snapshot.value?['groups'], isA<List<dynamic>>());

      // 恢复后不再轮询。
      async.elapse(const Duration(seconds: 6));
      expect(connector.playbackCalls, callsAfterRecovery);

      unawaited(socket.dispose());
      async.flushMicrotasks();
    });
  });

  test('重连后保留 seq 基线，旧事件继续丢弃', () {
    fakeAsync((async) {
      final connector = _FakeConnector();
      final socket = PlaybackSocket(connector: connector);
      final received = <int>[];
      socket.events.listen((event) => received.add(event.seq));

      socket.connect();
      async.flushMicrotasks();
      final first = connector.connections.single;
      first.add(_event(5));
      async.flushMicrotasks();
      expect(received, <int>[5]);

      unawaited(first.finish());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(connector.connections, hasLength(2));

      final second = connector.connections.last;
      second.add(_event(6));
      second.add(_event(4));
      async.flushMicrotasks();

      expect(received, <int>[5, 6]);
      expect(socket.lastSeq, 6);

      unawaited(socket.dispose());
      async.flushMicrotasks();
    });
  });

  test('重连后服务端 seq 回退时重置基线', () {
    fakeAsync((async) {
      final connector = _FakeConnector();
      final socket = PlaybackSocket(connector: connector);
      final received = <int>[];
      socket.events.listen((event) => received.add(event.seq));

      socket.connect();
      async.flushMicrotasks();
      connector.connections.single.add(_event(5));
      async.flushMicrotasks();
      expect(received, <int>[5]);

      unawaited(connector.connections.single.finish());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));

      // 服务端重启：seq 从 1 重新开始，新连接首条事件必须被接受。
      connector.connections.last.add(_event(1));
      async.flushMicrotasks();
      expect(received, <int>[5, 1]);
      expect(socket.lastSeq, 1);

      unawaited(socket.dispose());
      async.flushMicrotasks();
    });
  });

  test('坏消息不打断事件流', () async {
    final connector = _FakeConnector();
    final socket = PlaybackSocket(connector: connector);
    final received = <int>[];
    final subscription = socket.events.listen(
      (event) => received.add(event.seq),
    );

    socket.connect();
    await pumpEventQueue();
    final connection = connector.connections.single;
    connection.add('not json');
    connection.add('{"type":"state"}');
    connection.add(_event(1));
    await pumpEventQueue();

    expect(received, <int>[1]);

    await subscription.cancel();
    await socket.dispose();
  });

  test('eventsUri 使用 ws/wss 并携带 ticket', () {
    final dio = Dio();
    addTearDown(dio.close);
    final https = DioPlaybackConnector(
      dio: dio,
      baseUrl: 'https://example.com:8443',
    );
    final secure = https.eventsUri('a b');
    expect(secure.scheme, 'wss');
    expect(secure.host, 'example.com');
    expect(secure.port, 8443);
    expect(secure.path, '/api/v1/playback/events');
    expect(secure.queryParameters['ticket'], 'a b');

    final http = DioPlaybackConnector(dio: dio, baseUrl: 'http://example.com');
    expect(http.eventsUri('t').scheme, 'ws');
  });
}
