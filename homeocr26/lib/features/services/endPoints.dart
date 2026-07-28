
enum EndPoint {
  qrFetch("api/flutter/get_qr_details"),
  addMedicineQty("api/flutter/add_to_invoice"),
  customerInvoiceList("api/flutter/get_customer_invoice_list"),
  supplierInvoiceList("api/flutter/get_supplier_invoice_list"),
  stockList("api/flutter/get_stock_list"),
  netAmountYesterday("api/flutter/get_net_amount_yesterday"),
  paymentHistory("api/flutter/get_payment_history"),
  chequeClearance("api/flutter/get_cheque_clearance"),
  employeePerformance("api/flutter/get_employee_performance"),
  login("api/flutter/login"),
  supplierAdd("api/flutter/add_to_supplier_invoice");
  final String path;
  const EndPoint(this.path);
}