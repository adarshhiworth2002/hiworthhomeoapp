enum Environment { Production, Development }

/// Laravel Flutter API host (`/api/flutter/...`) and Customer Web View site.
final String baseApi = "http://46.37.122.167:8000/";
// final String baseApi = "https://hiworthtest.com/";
// final String baseApi = "http://94.249.151.147:8075/";

/// Legacy Odoo host (RPC disabled). WebView uses [baseApi] / [liveBaseApi].
final String odooBaseApi = "http://46.37.122.167:8000/";
// final String odooBaseApi = "https://hiworthtest.com/";

final String liveBaseApi = "http://46.37.122.167:8000/";
// final String liveBaseApi = "https://hiworthtest.com/";
final String liveOdooBaseApi = "http://46.37.122.167:8000/";
// final String liveOdooBaseApi = "https://hiworthtest.com/";

/// When false, [OdooRpcHelper] is a no-op. WebView opens the Laravel website.
const bool enableOdooRpc = false;
