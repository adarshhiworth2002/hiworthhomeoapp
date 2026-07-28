import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/cheque_clearance_service.dart';
import '../models/cheque_clearance_model.dart';
import 'login_viewmodel.dart';

class ChequeClearanceViewModel extends ChangeNotifier {
  bool loading = false;
  String error = '';
  List<ChequeClearanceModel> items = [];

  static Future<List<ChequeClearanceModel>> prefetch(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    final sessionId = loginModel.sessionId;
    if (sessionId == null || sessionId.isEmpty) return const [];
    await ChequeClearanceService.prefetch(
      sessionId,
      forceRefresh: forceRefresh,
    );
    return ChequeClearanceService.cachedItems ?? const [];
  }

  Future<void> fetch(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    if (!forceRefresh && ChequeClearanceService.hasFreshCache) {
      items = List<ChequeClearanceModel>.from(
        ChequeClearanceService.cachedItems ?? const [],
      );
      error = '';
      notifyListeners();
      return;
    }

    try {
      if (!silent) {
        loading = true;
        error = '';
        if (items.isEmpty) {
          notifyListeners();
        }
      }

      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      items = await ChequeClearanceService.fetch(
        sessionId: loginModel.sessionId!,
        forceRefresh: forceRefresh,
      );
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
