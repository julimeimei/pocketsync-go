class RemoteTask {
  const RemoteTask({
    required this.id,
    required this.clientId,
    required this.title,
    required this.description,
    required this.completed,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory RemoteTask.fromJson(Map<String, Object?> json) {
    return RemoteTask(
      id: _readString(json, 'id'),
      clientId: _readString(json, 'client_id'),
      title: _readString(json, 'title'),
      description: _readString(json, 'description'),
      completed: _readBool(json, 'completed'),
      version: _readInt(json, 'version'),
      createdAt: _readDateTime(json, 'created_at'),
      updatedAt: _readDateTime(json, 'updated_at'),
      deletedAt: _readNullableDateTime(json, 'deleted_at'),
    );
  }

  final String id;
  final String clientId;
  final String title;
  final String description;
  final bool completed;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

class CreateRemoteTaskRequest {
  const CreateRemoteTaskRequest({
    required this.clientId,
    required this.title,
    required this.description,
    required this.completed,
    required this.updatedAt,
  });

  final String clientId;
  final String title;
  final String description;
  final bool completed;
  final DateTime updatedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'client_id': clientId,
      'title': title,
      'description': description,
      'completed': completed,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }
}

class UpdateRemoteTaskRequest {
  const UpdateRemoteTaskRequest({
    required this.title,
    required this.description,
    required this.completed,
    required this.expectedVersion,
    required this.updatedAt,
  });

  final String title;
  final String description;
  final bool completed;
  final int expectedVersion;
  final DateTime updatedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'title': title,
      'description': description,
      'completed': completed,
      'expected_version': expectedVersion,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }
}

class DeleteRemoteTaskRequest {
  const DeleteRemoteTaskRequest({
    required this.expectedVersion,
    required this.deletedAt,
  });

  final int expectedVersion;
  final DateTime deletedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'expected_version': expectedVersion,
      'deleted_at': deletedAt.toUtc().toIso8601String(),
    };
  }
}

String _readString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is String) {
    return value;
  }

  throw FormatException('$key must be a string');
}

bool _readBool(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is bool) {
    return value;
  }

  throw FormatException('$key must be a boolean');
}

int _readInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is int) {
    return value;
  }

  throw FormatException('$key must be an integer');
}

DateTime _readDateTime(Map<String, Object?> json, String key) {
  return _parseDateTime(_readString(json, key), key);
}

DateTime? _readNullableDateTime(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return _parseDateTime(value, key);
  }

  throw FormatException('$key must be a string or null');
}

DateTime _parseDateTime(String value, String key) {
  try {
    return DateTime.parse(value).toUtc();
  } on FormatException {
    throw FormatException('$key must be an RFC3339 timestamp');
  }
}
