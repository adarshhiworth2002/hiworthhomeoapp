class SessionHelper {
  static String cookie(String? sessionId) {
    final value = sessionId?.trim() ?? '';
    if (value.isEmpty) return '';
    if (value.contains('=')) return value;
    return 'session_id=$value';
  }
}
