enum Environment { Production, Development }

/// Laravel Flutter API host (`/api/flutter/...`) and Customer Web View site.
final String baseApi = "https://hiworthtest.com/";
// final String baseApi = "http://94.249.151.147:8075/";

/// Legacy Odoo host (RPC disabled). WebView uses [baseApi] / [liveBaseApi].
final String odooBaseApi = "https://hiworthtest.com/";

final String liveBaseApi = "https://hiworthtest.com/";
final String liveOdooBaseApi = "https://hiworthtest.com/";

/// When false, [OdooRpcHelper] is a no-op. WebView opens the Laravel website.
const bool enableOdooRpc = false;
