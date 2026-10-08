import 'remote_task_models.dart';

enum TaskRemoteExceptionKind {
  validation,
  invalidJson,
  invalidSince,
  notFound,
  methodNotAllowed,
  conflict,
  bodyTooLarge,
  notReady,
  server,
  timeout,
  cancelled,
  network,
  unexpectedResponse,
  unknown,
}

class TaskRemoteException implements Exception {
  const TaskRemoteException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.code,
    this.serverTask,
    this.cause,
  });

  final TaskRemoteExceptionKind kind;
  final String message;
  final int? statusCode;
  final String? code;
  final RemoteTask? serverTask;
  final Object? cause;

  bool get isRetryable {
    return switch (kind) {
      TaskRemoteExceptionKind.timeout ||
      TaskRemoteExceptionKind.network ||
      TaskRemoteExceptionKind.notReady ||
      TaskRemoteExceptionKind.server => true,
      _ => false,
    };
  }

  @override
  String toString() {
    final String status = statusCode == null ? '' : ' status=$statusCode';
    final String remoteCode = code == null ? '' : ' code=$code';
    return 'TaskRemoteException(kind=$kind$status$remoteCode, message=$message)';
  }
}
