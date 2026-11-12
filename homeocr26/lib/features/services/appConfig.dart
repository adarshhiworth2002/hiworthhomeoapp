import 'base_api.dart';

class AppConfig {
  static Environment env = Environment.Development;

  /// Laravel `/api/flutter/*` base.
  static String get baseAppUrl =>
      env == Environment.Production ? liveBaseApi : baseApi;

  /// Same Laravel website as [baseAppUrl] — used by Customer Web View.
  static String get odooBaseUrl => baseAppUrl;

  /// Customer Web View / pharmacy website origin (same host as Flutter APIs).
  static String get webViewBaseUrl => baseAppUrl;

  /// App feature RPC to Odoo is off; Flutter local + Laravel APIs only.
  static bool get odooRpcEnabled => enableOdooRpc;
}
