import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dio_provider.dart';
import 'remote_task_models.dart';
import 'task_remote_exception.dart';

final Provider<TaskRemoteApiClient> taskRemoteApiClientProvider =
    Provider<TaskRemoteApiClient>((ref) {
      return TaskRemoteApiClient(ref.watch(dioProvider));
    });

class TaskRemoteApiClient {
  const TaskRemoteApiClient(this._dio);

  final Dio _dio;

  Future<RemoteTask> createTask(CreateRemoteTaskRequest request) async {
    final Response<Object?> response = await _send(
      () => _dio.post<Object?>('/tasks', data: request.toJson()),
    );
    return _readTask(response);
  }

  Future<List<RemoteTask>> listTasks({DateTime? since}) async {
    final Response<Object?> response = await _send(
      () => _dio.get<Object?>(
        '/tasks',
        queryParameters: since == null
            ? null
            : <String, Object?>{'since': since.toUtc().toIso8601String()},
      ),
    );
    _ensureSuccess(response);

    final Object? body = response.data;
    if (body is! Map<String, Object?>) {
      throw _unexpectedResponse();
    }

    final Object? tasks = body['tasks'];
    if (tasks is! List<Object?>) {
      throw _unexpectedResponse();
    }

    try {
      return tasks
          .map((Object? item) {
            if (item is! Map<String, Object?>) {
              throw const FormatException('task item must be an object');
            }
            return RemoteTask.fromJson(item);
          })
          .toList(growable: false);
    } on FormatException catch (error) {
      throw _unexpectedResponse(cause: error);
    }
  }

  Future<RemoteTask> getTask(String id) async {
    final Response<Object?> response = await _send(
      () => _dio.get<Object?>(_taskPath(id)),
    );
    return _readTask(response);
  }

  Future<RemoteTask> updateTask(
    String id,
    UpdateRemoteTaskRequest request,
  ) async {
    final Response<Object?> response = await _send(
      () => _dio.put<Object?>(_taskPath(id), data: request.toJson()),
    );
    return _readTask(response);
  }

  Future<RemoteTask> deleteTask(
    String id,
    DeleteRemoteTaskRequest request,
  ) async {
    final Response<Object?> response = await _send(
      () => _dio.delete<Object?>(_taskPath(id), data: request.toJson()),
    );
    return _readTask(response);
  }

  Future<Response<Object?>> _send(
    Future<Response<Object?>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  RemoteTask _readTask(Response<Object?> response) {
    _ensureSuccess(response);

    final Object? body = response.data;
    if (body is! Map<String, Object?>) {
      throw _unexpectedResponse();
    }

    try {
      return RemoteTask.fromJson(body);
    } on FormatException catch (error) {
      throw _unexpectedResponse(cause: error);
    }
  }

  void _ensureSuccess(Response<Object?> response) {
    final int? statusCode = response.statusCode;
    if (statusCode != null && statusCode >= 200 && statusCode < 300) {
      return;
    }

    throw _mapErrorResponse(response);
  }

  String _taskPath(String id) {
    return '/tasks/${Uri.encodeComponent(id)}';
  }

  TaskRemoteException _mapDioException(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout => TaskRemoteException(
        kind: TaskRemoteExceptionKind.timeout,
        message: 'request timed out',
        cause: error,
      ),
      DioExceptionType.cancel => TaskRemoteException(
        kind: TaskRemoteExceptionKind.cancelled,
        message: 'request was cancelled',
        cause: error,
      ),
      DioExceptionType.connectionError ||
      DioExceptionType.badCertificate => TaskRemoteException(
        kind: TaskRemoteExceptionKind.network,
        message: 'network request failed',
        cause: error,
      ),
      DioExceptionType.badResponse => _mapErrorResponse(error.response),
      DioExceptionType.unknown => TaskRemoteException(
        kind: TaskRemoteExceptionKind.network,
        message: 'network request failed',
        cause: error,
      ),
    };
  }

  TaskRemoteException _mapErrorResponse(Response<Object?>? response) {
    final int? statusCode = response?.statusCode;
    final Object? body = response?.data;
    final _RemoteErrorPayload payload = _RemoteErrorPayload.fromBody(body);
    final RemoteTask? serverTask = _readConflictTask(payload);
    final String code = payload.code ?? _defaultCodeForStatus(statusCode);

    return TaskRemoteException(
      kind: _kindFor(statusCode, code),
      statusCode: statusCode,
      code: code,
      message: payload.message ?? _defaultMessageForStatus(statusCode),
      serverTask: serverTask,
    );
  }

  RemoteTask? _readConflictTask(_RemoteErrorPayload payload) {
    final Object? serverTask = payload.serverTask;
    if (serverTask is! Map<String, Object?>) {
      return null;
    }

    try {
      return RemoteTask.fromJson(serverTask);
    } on FormatException {
      return null;
    }
  }

  TaskRemoteExceptionKind _kindFor(int? statusCode, String code) {
    if (statusCode == 409 || code == 'conflict') {
      return TaskRemoteExceptionKind.conflict;
    }

    return switch (code) {
      'validation_error' => TaskRemoteExceptionKind.validation,
      'invalid_json' => TaskRemoteExceptionKind.invalidJson,
      'invalid_since' => TaskRemoteExceptionKind.invalidSince,
      'not_found' => TaskRemoteExceptionKind.notFound,
      'method_not_allowed' => TaskRemoteExceptionKind.methodNotAllowed,
      'body_too_large' => TaskRemoteExceptionKind.bodyTooLarge,
      'not_ready' => TaskRemoteExceptionKind.notReady,
      'internal_error' => TaskRemoteExceptionKind.server,
      _ => switch (statusCode) {
        400 => TaskRemoteExceptionKind.validation,
        404 => TaskRemoteExceptionKind.notFound,
        405 => TaskRemoteExceptionKind.methodNotAllowed,
        413 => TaskRemoteExceptionKind.bodyTooLarge,
        500 => TaskRemoteExceptionKind.server,
        503 => TaskRemoteExceptionKind.notReady,
        _ => TaskRemoteExceptionKind.unknown,
      },
    };
  }

  String _defaultCodeForStatus(int? statusCode) {
    return switch (statusCode) {
      400 => 'validation_error',
      404 => 'not_found',
      405 => 'method_not_allowed',
      409 => 'conflict',
      413 => 'body_too_large',
      500 => 'internal_error',
      503 => 'not_ready',
      _ => 'unknown_error',
    };
  }

  String _defaultMessageForStatus(int? statusCode) {
    return switch (statusCode) {
      400 => 'request was invalid',
      404 => 'task was not found',
      405 => 'method is not allowed',
      409 => 'task has changed on the server',
      413 => 'request body is too large',
      500 => 'server error',
      503 => 'service is not ready',
      _ => 'request failed',
    };
  }

  TaskRemoteException _unexpectedResponse({Object? cause}) {
    return TaskRemoteException(
      kind: TaskRemoteExceptionKind.unexpectedResponse,
      message: 'unexpected response from server',
      cause: cause,
    );
  }
}

class _RemoteErrorPayload {
  const _RemoteErrorPayload({this.code, this.message, this.serverTask});

  factory _RemoteErrorPayload.fromBody(Object? body) {
    if (body is! Map<String, Object?>) {
      return const _RemoteErrorPayload();
    }

    final Object? error = body['error'];
    if (error is! Map<String, Object?>) {
      return const _RemoteErrorPayload();
    }

    return _RemoteErrorPayload(
      code: error['code'] is String ? error['code'] as String : null,
      message: error['message'] is String ? error['message'] as String : null,
      serverTask: error['server_task'],
    );
  }

  final String? code;
  final String? message;
  final Object? serverTask;
}
