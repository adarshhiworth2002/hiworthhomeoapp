import 'package:http/http.dart';

abstract class WebAPI {

  Future<Response> qrFetch({required Map<String, dynamic> userDetails, required String sessionId});
  Future<Response> addMedicineQty({required Map<String, dynamic> userDetails,required String sessionId});
  Future<Response> fetchInvoiceList({
    required String endpointPath,
    required Map<String, dynamic> userDetails,
    required String sessionId,
    Duration timeout = const Duration(seconds: 60),
    bool logResponseBody = true,
  });
  Future<Response> login({required Map<String, dynamic> userDetails});
  Future<Response> addMedicineQtySupplier({required Map<String, dynamic> userDetails,required String sessionId});

}