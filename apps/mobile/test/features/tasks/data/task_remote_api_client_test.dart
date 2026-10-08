import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketsync_mobile/features/tasks/data/remote_task_models.dart';
import 'package:pocketsync_mobile/features/tasks/data/task_remote_api_client.dart';
import 'package:pocketsync_mobile/features/tasks/data/task_remote_exception.dart';

void main() {
  test('creates a task and parses the remote response', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter((
      FakeHttpRequest request,
    ) {
      expect(request.method, 'POST');
      expect(request.path, '/tasks');
      expect(request.jsonBody, <String, Object?>{
        'client_id': 'local-1',
        'title': 'Buy coffee',
        'description': '',
        'completed': false,
        'updated_at': '2026-08-14T21:00:00.000Z',
      });

      return jsonResponse(201, remoteTaskJson(id: 'remote-1'));
    });
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    final RemoteTask task = await client.createTask(
      CreateRemoteTaskRequest(
        clientId: 'local-1',
        title: 'Buy coffee',
        description: '',
        completed: false,
        updatedAt: fixedTime(),
      ),
    );

    expect(task.id, 'remote-1');
    expect(task.clientId, 'local-1');
    expect(task.version, 1);
    expect(task.updatedAt, fixedTime());
  });

  test('lists tasks with an optional since timestamp', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter((
      FakeHttpRequest request,
    ) {
      expect(request.method, 'GET');
      expect(request.path, '/tasks');
      expect(request.queryParameters['since'], '2026-08-14T21:00:00.000Z');

      return jsonResponse(200, <String, Object?>{
        'tasks': <Object?>[
          remoteTaskJson(id: 'remote-1'),
          remoteTaskJson(
            id: 'remote-2',
            clientId: 'local-2',
            title: 'Second task',
            version: 2,
          ),
        ],
      });
    });
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    final List<RemoteTask> tasks = await client.listTasks(since: fixedTime());

    expect(tasks, hasLength(2));
    expect(tasks.first.id, 'remote-1');
    expect(tasks.last.version, 2);
  });

  test('gets a task by encoded remote id', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter((
      FakeHttpRequest request,
    ) {
      expect(request.method, 'GET');
      expect(request.path, '/tasks/remote%2F1');
      return jsonResponse(200, remoteTaskJson(id: 'remote/1'));
    });
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    final RemoteTask task = await client.getTask('remote/1');

    expect(task.id, 'remote/1');
  });

  test('updates a task and sends the expected version', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter((
      FakeHttpRequest request,
    ) {
      expect(request.method, 'PUT');
      expect(request.path, '/tasks/remote-1');
      expect(request.jsonBody, <String, Object?>{
        'title': 'Updated',
        'description': 'Remote edit',
        'completed': true,
        'expected_version': 1,
        'updated_at': '2026-08-14T21:00:00.000Z',
      });

      return jsonResponse(200, remoteTaskJson(title: 'Updated', version: 2));
    });
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    final RemoteTask task = await client.updateTask(
      'remote-1',
      UpdateRemoteTaskRequest(
        title: 'Updated',
        description: 'Remote edit',
        completed: true,
        expectedVersion: 1,
        updatedAt: fixedTime(),
      ),
    );

    expect(task.title, 'Updated');
    expect(task.version, 2);
  });

  test('deletes a task with a tombstone request body', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter((
      FakeHttpRequest request,
    ) {
      expect(request.method, 'DELETE');
      expect(request.path, '/tasks/remote-1');
      expect(request.jsonBody, <String, Object?>{
        'expected_version': 1,
        'deleted_at': '2026-08-14T21:00:00.000Z',
      });

      return jsonResponse(
        200,
        remoteTaskJson(deletedAt: '2026-08-14T21:00:00Z', version: 2),
      );
    });
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    final RemoteTask task = await client.deleteTask(
      'remote-1',
      DeleteRemoteTaskRequest(expectedVersion: 1, deletedAt: fixedTime()),
    );

    expect(task.deletedAt, fixedTime());
    expect(task.version, 2);
  });

  test('maps validation errors into domain exceptions', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter(
      (_) =>
          jsonResponse(400, errorJson('validation_error', 'title is required')),
    );
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    await expectLater(
      client.createTask(
        CreateRemoteTaskRequest(
          clientId: 'local-1',
          title: '',
          description: '',
          completed: false,
          updatedAt: fixedTime(),
        ),
      ),
      throwsA(
        isA<TaskRemoteException>()
            .having(
              (TaskRemoteException error) => error.kind,
              'kind',
              TaskRemoteExceptionKind.validation,
            )
            .having(
              (TaskRemoteException error) => error.isRetryable,
              'isRetryable',
              isFalse,
            ),
      ),
    );
  });

  test('maps not found errors into domain exceptions', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter(
      (_) => jsonResponse(404, errorJson('not_found', 'task not found')),
    );
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    await expectLater(
      client.getTask('missing'),
      throwsA(
        isA<TaskRemoteException>().having(
          (TaskRemoteException error) => error.kind,
          'kind',
          TaskRemoteExceptionKind.notFound,
        ),
      ),
    );
  });

  test('maps conflict responses with the server task', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter(
      (_) => jsonResponse(409, <String, Object?>{
        'error': <String, Object?>{
          'code': 'conflict',
          'message': 'task has changed on the server',
          'server_task': remoteTaskJson(
            id: 'remote-1',
            title: 'Server title',
            version: 3,
          ),
        },
      }),
    );
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    await expectLater(
      client.updateTask(
        'remote-1',
        UpdateRemoteTaskRequest(
          title: 'Local title',
          description: '',
          completed: false,
          expectedVersion: 1,
          updatedAt: fixedTime(),
        ),
      ),
      throwsA(
        isA<TaskRemoteException>()
            .having(
              (TaskRemoteException error) => error.kind,
              'kind',
              TaskRemoteExceptionKind.conflict,
            )
            .having(
              (TaskRemoteException error) => error.serverTask?.title,
              'serverTask.title',
              'Server title',
            ),
      ),
    );
  });

  test(
    'keeps conflict kind when the server task payload is malformed',
    () async {
      final FakeHttpClientAdapter adapter = FakeHttpClientAdapter(
        (_) => jsonResponse(409, <String, Object?>{
          'error': <String, Object?>{
            'code': 'conflict',
            'message': 'task has changed on the server',
            'server_task': <String, Object?>{'id': 'remote-1'},
          },
        }),
      );
      final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

      await expectLater(
        client.updateTask(
          'remote-1',
          UpdateRemoteTaskRequest(
            title: 'Local title',
            description: '',
            completed: false,
            expectedVersion: 1,
            updatedAt: fixedTime(),
          ),
        ),
        throwsA(
          isA<TaskRemoteException>()
              .having(
                (TaskRemoteException error) => error.kind,
                'kind',
                TaskRemoteExceptionKind.conflict,
              )
              .having(
                (TaskRemoteException error) => error.serverTask,
                'serverTask',
                isNull,
              ),
        ),
      );
    },
  );

  test(
    'maps malformed server errors into retryable server exceptions',
    () async {
      final FakeHttpClientAdapter adapter = FakeHttpClientAdapter(
        (_) => jsonResponse(500, <String, Object?>{'unexpected': true}),
      );
      final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

      await expectLater(
        client.getTask('remote-1'),
        throwsA(
          isA<TaskRemoteException>()
              .having(
                (TaskRemoteException error) => error.kind,
                'kind',
                TaskRemoteExceptionKind.server,
              )
              .having(
                (TaskRemoteException error) => error.isRetryable,
                'isRetryable',
                isTrue,
              )
              .having(
                (TaskRemoteException error) => error.message,
                'message',
                'server error',
              ),
        ),
      );
    },
  );

  test(
    'maps malformed task list items into unexpected response errors',
    () async {
      final FakeHttpClientAdapter adapter = FakeHttpClientAdapter(
        (_) => jsonResponse(200, <String, Object?>{
          'tasks': <Object?>[
            <String, Object?>{'id': 'remote-1'},
          ],
        }),
      );
      final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

      await expectLater(
        client.listTasks(),
        throwsA(
          isA<TaskRemoteException>().having(
            (TaskRemoteException error) => error.kind,
            'kind',
            TaskRemoteExceptionKind.unexpectedResponse,
          ),
        ),
      );
    },
  );

  test('maps timeout failures into retryable domain exceptions', () async {
    final FakeHttpClientAdapter adapter = FakeHttpClientAdapter((
      FakeHttpRequest request,
    ) {
      throw DioException(
        requestOptions: request.options,
        type: DioExceptionType.connectionTimeout,
      );
    });
    final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

    await expectLater(
      client.getTask('remote-1'),
      throwsA(
        isA<TaskRemoteException>()
            .having(
              (TaskRemoteException error) => error.kind,
              'kind',
              TaskRemoteExceptionKind.timeout,
            )
            .having(
              (TaskRemoteException error) => error.isRetryable,
              'isRetryable',
              isTrue,
            ),
      ),
    );
  });

  test(
    'maps malformed successful responses into unexpected response errors',
    () async {
      final FakeHttpClientAdapter adapter = FakeHttpClientAdapter(
        (_) => jsonResponse(200, <String, Object?>{'tasks': <Object?>[]}),
      );
      final TaskRemoteApiClient client = TaskRemoteApiClient(testDio(adapter));

      await expectLater(
        client.getTask('remote-1'),
        throwsA(
          isA<TaskRemoteException>().having(
            (TaskRemoteException error) => error.kind,
            'kind',
            TaskRemoteExceptionKind.unexpectedResponse,
          ),
        ),
      );
    },
  );
}

Dio testDio(HttpClientAdapter adapter) {
  return Dio(
    BaseOptions(
      baseUrl: 'http://api.test',
      connectTimeout: const Duration(seconds: 1),
      sendTimeout: const Duration(seconds: 1),
      receiveTimeout: const Duration(seconds: 1),
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
      validateStatus: (_) => true,
    ),
  )..httpClientAdapter = adapter;
}

ResponseBody jsonResponse(int statusCode, Object? body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

Map<String, Object?> remoteTaskJson({
  String id = 'remote-1',
  String clientId = 'local-1',
  String title = 'Buy coffee',
  String description = '',
  bool completed = false,
  int version = 1,
  String createdAt = '2026-08-14T21:00:00Z',
  String updatedAt = '2026-08-14T21:00:00Z',
  String? deletedAt,
}) {
  return <String, Object?>{
    'id': id,
    'client_id': clientId,
    'title': title,
    'description': description,
    'completed': completed,
    'version': version,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'deleted_at': deletedAt,
  };
}

Map<String, Object?> errorJson(String code, String message) {
  return <String, Object?>{
    'error': <String, Object?>{'code': code, 'message': message},
  };
}

DateTime fixedTime() {
  return DateTime.utc(2026, 8, 14, 21);
}

class FakeHttpClientAdapter implements HttpClientAdapter {
  FakeHttpClientAdapter(this._handler);

  final FutureOr<ResponseBody> Function(FakeHttpRequest request) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String? body = await _readBody(requestStream);
    return _handler(
      FakeHttpRequest(
        options: options,
        method: options.method,
        path: options.path,
        queryParameters: options.queryParameters,
        body: body,
      ),
    );
  }

  @override
  void close({bool force = false}) {}

  Future<String?> _readBody(Stream<Uint8List>? requestStream) async {
    if (requestStream == null) {
      return null;
    }

    final List<int> bytes = <int>[];
    await for (final Uint8List chunk in requestStream) {
      bytes.addAll(chunk);
    }

    return utf8.decode(bytes);
  }
}

class FakeHttpRequest {
  const FakeHttpRequest({
    required this.options,
    required this.method,
    required this.path,
    required this.queryParameters,
    required this.body,
  });

  final RequestOptions options;
  final String method;
  final String path;
  final Map<String, dynamic> queryParameters;
  final String? body;

  Map<String, Object?> get jsonBody {
    final String? text = body;
    if (text == null || text.isEmpty) {
      return <String, Object?>{};
    }

    return jsonDecode(text) as Map<String, Object?>;
  }
}
