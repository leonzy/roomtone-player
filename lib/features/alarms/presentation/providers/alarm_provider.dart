import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../data/alarm_api.dart';
import '../../domain/alarm_models.dart';

/// 闹钟 API Provider。
final alarmApiProvider = Provider<AlarmApi>((ref) {
  return AlarmApi(dio: ref.watch(dioProvider));
});

class AlarmState {
  const AlarmState({
    this.items = const <Alarm>[],
    this.loading = false,
    this.busy = false,
    this.error = '',
    this.notice = '',
  });

  final List<Alarm> items;
  final bool loading;
  final bool busy;
  final String error;
  final String notice;

  AlarmState copyWith({
    List<Alarm>? items,
    bool? loading,
    bool? busy,
    String? error,
    String? notice,
  }) => AlarmState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    error: error ?? this.error,
    notice: notice ?? this.notice,
  );
}

/// 闹钟列表控制器：所有写操作成功后都重新拉一次列表。
///
/// 不做本地增量：触发时间、last_fired_at 由服务端维护，本地拼容易和后端
/// 不一致（尤其是"仅一次"闹钟响过之后仍然留在列表里）。
class AlarmController extends Notifier<AlarmState> {
  AlarmApi get _api => ref.read(alarmApiProvider);

  @override
  AlarmState build() => const AlarmState();

  Future<void> load() async {
    state = state.copyWith(loading: true, error: '');
    try {
      final items = await _api.list();
      state = state.copyWith(items: items, loading: false);
    } on ApiException catch (e) {
      state = state.copyWith(loading: false, error: e.message);
    }
  }

  Future<bool> create(AlarmDraft draft) => _run(() async {
    await _api.create(draft);
    return '已创建闹钟';
  });

  Future<bool> update(String id, AlarmDraft draft) => _run(() async {
    await _api.update(id, draft);
    return '已保存';
  });

  Future<bool> delete(String id) => _run(() async {
    await _api.delete(id);
    return '已删除';
  });

  Future<bool> trigger(String id) => _run(() async {
    await _api.trigger(id);
    return '已触发，正在起播';
  });

  Future<bool> toggle(Alarm alarm, bool enabled) =>
      update(alarm.id, alarm.copyWith(enabled: enabled).toDraft());

  Future<bool> _run(Future<String> Function() action) async {
    state = state.copyWith(busy: true, error: '', notice: '');
    try {
      final notice = await action();
      final items = await _api.list();
      state = state.copyWith(items: items, busy: false, notice: notice);
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return false;
    }
  }

  void clearError() => state = state.copyWith(error: '');
  void clearNotice() => state = state.copyWith(notice: '');
}

final alarmControllerProvider =
    NotifierProvider<AlarmController, AlarmState>(AlarmController.new);
