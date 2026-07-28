import 'base_api.dart';

class AppConfig {
  static Environment env = Environment.Development;

  static String get baseAppUrl => env==Environment.Production ? liveBaseApi : baseApi;

}