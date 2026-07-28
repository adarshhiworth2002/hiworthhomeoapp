class InvoiceSuggestion {
  const InvoiceSuggestion({
    required this.prefix,
    required this.state,
    this.paymentState,
    this.isPaid = false,
  });

  final String prefix;
  final String state;
  final String? paymentState;
  final bool isPaid;

  bool get isDraft => _normalizedState == 'draft' && !isPaid;

  String get statusLabel {
    if (isPaid) return 'Paid';

    final payment = paymentState?.toLowerCase().trim();
    if (payment == 'paid' || payment == 'in_payment') return 'Paid';
    if (_normalizedState == 'paid') return 'Paid';

    switch (_normalizedState) {
      case 'draft':
        return 'Draft';
      case 'posted':
      case 'open':
        return 'Open';
      default:
        return state.isEmpty ? 'Unknown' : state;
    }
  }

  String get warningMessage {
    if (isDraft) return '';
    final label = statusLabel.toLowerCase();
    if (isPaid ||
        paymentState?.toLowerCase().trim() == 'paid' ||
        state.toLowerCase().trim() == 'paid') {
      return 'This supplier bill is paid and cannot be modified '
          '(reconciled journal entry). You can only add quantity to draft bills.';
    }
    return 'This supplier bill is $label and cannot be modified. '
        'You can only add quantity to draft bills.';
  }

  String get _normalizedState => state.toLowerCase().trim();
}
