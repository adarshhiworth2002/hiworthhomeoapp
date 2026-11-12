class ApiRequestHelper {
  /// Odoo-compatible envelope + top-level keys for Laravel
  /// (`FlutterApiController` often reads top-level fields, not only `params`).
  static Map<String, dynamic> jsonRpcCall(dynamic params) {
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'call',
      'params': params,
      'id': 1,
    };
    if (params is Map) {
      params.forEach((key, value) {
        final k = '$key';
        if (k.isEmpty || k == 'jsonrpc' || k == 'method' || k == 'params') {
          return;
        }
        body[k] = value;
      });
    }
    return body;
  }

  /// Laravel `POST /api/flutter/login` expects a flat body:
  /// `{ "login"|"email": "...", "password": "..." }`
  static Map<String, dynamic> loginCall({
    required String db,
    required String login,
    required String password,
  }) {
    return {
      'login': login.trim(),
      'email': login.trim(),
      'password': password,
      'db': db,
    };
  }
}
