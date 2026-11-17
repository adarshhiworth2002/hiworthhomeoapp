enum EndPoint {
  qrFetch("api/flutter/get_qr_details"),
  addMedicineQty("api/flutter/add_to_invoice"),
  customerInvoiceList("api/flutter/get_customer_invoice_list"),
  customerInvoices("api/flutter/get_customer_invoices"),
  customerInvoice("api/flutter/get_customer_invoice"),
  customerInvoicePdf("api/flutter/get_customer_invoice_pdf"),
  customerInvoiceAutoPrint("api/pharmacy_mgmnt/auto_print_invoice"),
  customerPaymentPdf("api/flutter/get_customer_payment_pdf"),
  supplierInvoiceList("api/flutter/get_supplier_invoice_list"),
  stockList("api/flutter/get_stock_list"),
  stockDetail("api/flutter/get_stock"),
  netAmountYesterday("api/flutter/get_net_amount_yesterday"),
  paymentHistory("api/flutter/get_payment_history"),
  customerPaymentList("api/flutter/get_customer_payment_list"),
  customerPaymentDetail("api/flutter/get_customer_payment"),
  customerOpenBills("api/flutter/get_customer_open_bills"),
  createCustomerPayment("api/flutter/create_customer_payment"),
  processCustomerPayment("api/flutter/process_customer_payment"),
  actionCustomerPayment("api/flutter/action_customer_payment"),
  paymentBook("api/flutter/get_payment_book"),
  chequeClearance("api/flutter/get_cheque_clearance"),
  unpaidDues("api/flutter/get_unpaid_dues"),
  employeePerformance("api/flutter/get_employee_performance"),
  employeePerformanceList("api/flutter/get_employee_performance_list"),
  addToPackingSlip("api/flutter/add_to_packing_slip"),
  login("api/flutter/login"),
  supplierAdd("api/flutter/add_to_supplier_invoice");

  final String path;
  const EndPoint(this.path);
}
