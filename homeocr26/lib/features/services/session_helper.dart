class SessionHelper {
  static const jsonUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static Map<String, String> jsonHeaders({
    String? sessionId,
    String? apiToken,
  }) {
    final token = (apiToken ?? '').trim();
    final sid = (sessionId ?? '').trim();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': jsonUserAgent,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (sid.isNotEmpty) 'Cookie': cookie(sid),
    };
  }

  static String cookie(String? sessionId) {
    final value = sessionId?.trim() ?? '';
    if (value.isEmpty) return '';
    if (value.contains('=')) return value;
    return 'session_id=$value';
  }
}
