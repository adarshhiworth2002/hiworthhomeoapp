import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedAuth {
  const SavedAuth({
    required this.sessionId,
    required this.userName,
    required this.email,
    required this.password,
  });

  final String sessionId;
  final String userName;
  final String email;
  final String password;

  bool get hasCredentials =>
      sessionId.trim().isNotEmpty &&
      email.trim().isNotEmpty &&
      password.isNotEmpty;
}

/// Persists the last successful login so the app stays signed in
/// until the user taps Logout.
///
/// Writes a flushed file (survives process kill) and also SharedPreferences.
class AuthSessionStore {
  static const _fileName = 'auth_session.json';
  static const _prefsJsonKey = 'auth_session_json';
  static const _sessionKey = 'auth_session_id';
  static const _nameKey = 'auth_user_name';
  static const _emailKey = 'auth_email';
  static const _passwordKey = 'auth_password';

  static SavedAuth? _memory;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> save({
    required String? sessionId,
    required String? userName,
    required String? email,
    required String? password,
  }) async {
    final auth = SavedAuth(
      sessionId: (sessionId ?? '').trim(),
      userName: (userName ?? '').trim(),
      email: (email ?? '').trim(),
      password: password ?? '',
    );
    if (!auth.hasCredentials) return;
    _memory = auth;
    final payload = jsonEncode({
      'session_id': auth.sessionId,
      'user_name': auth.userName,
      'email': auth.email,
      'password': auth.password,
    });

    try {
      final file = await _file();
      await file.writeAsString(payload, flush: true);
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSessionStore.save file: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsJsonKey, payload);
      await prefs.setString(_sessionKey, auth.sessionId);
      await prefs.setString(_nameKey, auth.userName);
      await prefs.setString(_emailKey, auth.email);
      await prefs.setString(_passwordKey, auth.password);
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSessionStore.save prefs: $e');
    }
  }

  static Future<SavedAuth?> load() async {
    if (_memory != null && _memory!.hasCredentials) return _memory;

    try {
      final file = await _file();
      if (await file.exists()) {
        final parsed = _parse(await file.readAsString());
        if (parsed != null) {
          _memory = parsed;
          return parsed;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSessionStore.load file: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final fromJson = _parse(prefs.getString(_prefsJsonKey));
      if (fromJson != null) {
        _memory = fromJson;
        return fromJson;
      }
      final sid = (prefs.getString(_sessionKey) ?? '').trim();
      final mail = (prefs.getString(_emailKey) ?? '').trim();
      final pass = prefs.getString(_passwordKey) ?? '';
      if (sid.isNotEmpty && mail.isNotEmpty && pass.isNotEmpty) {
        final parsed = SavedAuth(
          sessionId: sid,
          userName: (prefs.getString(_nameKey) ?? '').trim(),
          email: mail,
          password: pass,
        );
        _memory = parsed;
        return parsed;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSessionStore.load prefs: $e');
    }
    return null;
  }

  static Future<void> clear() async {
    _memory = null;
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSessionStore.clear file: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsJsonKey);
      await prefs.remove(_sessionKey);
      await prefs.remove(_nameKey);
      await prefs.remove(_emailKey);
      await prefs.remove(_passwordKey);
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSessionStore.clear prefs: $e');
    }
  }

  static SavedAuth? _parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = json.decode(raw);
      if (map is! Map) return null;
      final auth = SavedAuth(
        sessionId: '${map['session_id'] ?? ''}'.trim(),
        userName: '${map['user_name'] ?? ''}'.trim(),
        email: '${map['email'] ?? ''}'.trim(),
        password: '${map['password'] ?? ''}',
      );
      return auth.hasCredentials ? auth : null;
    } catch (_) {
      return null;
    }
  }
}
