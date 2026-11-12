/// Shared success/error + payload unwrap for Odoo JSON-RPC and Laravel
/// Flutter-compatible responses.
class ApiResponseHelper {
  /// Accepts:
  /// - `{ "result": { "status": "success", ... } }`
  /// - `{ "status": "success", ... }`
  static bool isSuccess(Map<String, dynamic> response) {
    final payload = payloadMap(response);
    if (payload == null) return false;
    final status = '${payload['status'] ?? ''}'.trim().toLowerCase();
    if (status == 'error' || status == 'fail' || status == 'failed') {
      return false;
    }
    if (status == 'success' || status == 'ok') return true;
    // Some Laravel routes omit status but still return data.
    if (response.containsKey('error')) return false;
    return payload.isNotEmpty;
  }

  static String errorMessage(
    Map<String, dynamic> response, {
    String fallback = 'Something went wrong. Please try again.',
  }) {
    final payload = payloadMap(response);
    if (payload != null) {
      final message = payload['message'] ?? payload['error'];
      if (message != null && message.toString().trim().isNotEmpty) {
        return message.toString().trim();
      }
    }

    final error = response['error'];
    if (error is Map) {
      final data = error['data'];
      if (data is Map) {
        final dataMessage = data['message'];
        if (dataMessage != null && dataMessage.toString().trim().isNotEmpty) {
          return dataMessage.toString().trim();
        }
      }
      final errorMessage = error['message'];
      if (errorMessage != null && errorMessage.toString().trim().isNotEmpty) {
        return errorMessage.toString().trim();
      }
    }

    final top = response['message'];
    if (top != null && top.toString().trim().isNotEmpty) {
      return top.toString().trim();
    }

    return fallback;
  }

  /// Business payload map (`result` wrapper or top-level Laravel body).
  static Map<String, dynamic>? payloadMap(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    if (response.containsKey('status') ||
        response.containsKey('data') ||
        response.containsKey('session_id') ||
        response.containsKey('message')) {
      return Map<String, dynamic>.from(response);
    }
    return null;
  }

  /// Prefer nested `data` map when present, else the payload itself.
  static Map<String, dynamic> dataMap(Map<String, dynamic> response) {
    final payload = payloadMap(response) ?? response;
    final data = payload['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return Map<String, dynamic>.from(payload);
  }
}
