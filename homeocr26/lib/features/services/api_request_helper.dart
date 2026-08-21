class ApiRequestHelper {
  static Map<String, dynamic> jsonRpcCall(dynamic params) {
    return {
      'jsonrpc': '2.0',
      'method': 'call',
      'params': params,
      'id': 1,
    };
  }

  static Map<String, dynamic> loginCall({
    required String db,
    required String login,
    required String password,
  }) {
    return {
      'jsonrpc': '2.0',
      // 'method': 'call',
      // 'id': 1,
      'params': {
        'db': db,
        'login': login,
        'password': password,
      },
    };
  }
}
