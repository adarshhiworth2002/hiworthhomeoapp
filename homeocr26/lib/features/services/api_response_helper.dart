class ApiResponseHelper {
  static bool isSuccess(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is Map && result['status'] == 'success') {
      return true;
    }
    return false;
  }

  static String errorMessage(
    Map<String, dynamic> response, {
    String fallback = 'Something went wrong. Please try again.',
  }) {
    final result = response['result'];
    if (result is Map) {
      final message = result['message'];
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

    return fallback;
  }
}
