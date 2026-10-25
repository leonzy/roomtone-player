import 'package:dio/dio.dart';

import '../../../config/app_config.dart';
import '../../../core/network/api_exceptions.dart';
import '../domain/alarm_models.dart';

/// 服务端闹钟 API（`/api/v1/alarms`）。
///
/// 调度在服务端跑（15 秒一轮），客户端只负责增删改与"试听"。
class AlarmApi {
  AlarmApi({required this.dio});

  final Dio dio;

  String get _base => '${AppConfig.apiPrefix}/alarms';

  Future<List<Alarm>> list() async {
    try {
      final res = await dio.get<List<dynamic>>(_base);
      return (res.data ?? const [])
          .map((e) => Alarm.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<Alarm> create(AlarmDraft draft) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        _base,
        data: draft.toJson(),
      );
      return Alarm.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<Alarm> update(String id, AlarmDraft draft) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '$_base/$id',
        data: draft.toJson(),
      );
      return Alarm.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<void> delete(String id) async {
    try {
      await dio.delete<void>('$_base/$id');
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 立即触发（不写 last_fired_at，不影响今天的正常触发）。
  Future<void> trigger(String id) async {
    try {
      await dio.post<Map<String, dynamic>>('$_base/$id/test');
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }
}
