import 'dart:async';

import 'package:flutter/material.dart';

import '../services/invoice_helper.dart';
import '../services/invoice_suggestion.dart';
import '../theme.dart';
import '../widgets/show_dialog_custom.dart';

typedef InvoicePrefixSearch = Future<List<String>> Function(String prefix);
typedef InvoiceSuggestionSearch =
    Future<List<InvoiceSuggestion>> Function(String prefix);

class InvoicePrefixField extends StatefulWidget {
  const InvoicePrefixField({
    super.key,
    required this.controller,
    this.onSearch,
    this.onSearchSuggestions,
    this.warnOnNonDraftSelection = false,
    this.hintText = '0341',
    this.maxSuggestions = 5,
  });

  final TextEditingController controller;
  final InvoicePrefixSearch? onSearch;
  final InvoiceSuggestionSearch? onSearchSuggestions;
  final bool warnOnNonDraftSelection;
  final String hintText;
  final int maxSuggestions;

  @override
  State<InvoicePrefixField> createState() => _InvoicePrefixFieldState();
}

class _InvoicePrefixFieldState extends State<InvoicePrefixField> {
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  List<InvoiceSuggestion> _suggestions = [];
  InvoiceSuggestion? _matchedSuggestion;
  bool _loading = false;
  bool _showPanel = false;
  bool _searchedWithNoResults = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus && widget.controller.text.trim().isNotEmpty) {
      setState(() => _showPanel = true);
      _fetchSuggestions(widget.controller.text.trim());
    } else if (!_focusNode.hasFocus) {
      Future.delayed(const Duration(milliseconds: 180), () {
        if (mounted && !_focusNode.hasFocus) {
          setState(() => _showPanel = false);
        }
      });
    }
  }

  void _onTextChanged() {
    final text = widget.controller.text.trim();
    _debounce?.cancel();

    if (text.isEmpty) {
      setState(() {
        _suggestions = [];
        _matchedSuggestion = null;
        _loading = false;
        _showPanel = false;
        _searchedWithNoResults = false;
      });
      return;
    }

    setState(() {
      _showPanel = _focusNode.hasFocus;
      _loading = true;
      _searchedWithNoResults = false;
    });

    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(text);
    });
  }

  Future<void> _fetchSuggestions(String prefix) async {
    final List<InvoiceSuggestion> results;
    if (widget.onSearchSuggestions != null) {
      results = await widget.onSearchSuggestions!(prefix);
    } else if (widget.onSearch != null) {
      final prefixes = await widget.onSearch!(prefix);
      results = prefixes
          .map(
            (item) => InvoiceSuggestion(prefix: item, state: 'draft'),
          )
          .toList();
    } else {
      results = [];
    }

    if (!mounted) return;
    if (widget.controller.text.trim() != prefix) return;

    setState(() {
      _loading = false;
      _suggestions = results.take(widget.maxSuggestions).toList();
      _matchedSuggestion = _findExactMatch(prefix, results);
      _searchedWithNoResults = results.isEmpty;
      _showPanel =
          _focusNode.hasFocus && widget.controller.text.trim().isNotEmpty;
    });
  }

  InvoiceSuggestion? _findExactMatch(
    String prefix,
    List<InvoiceSuggestion> results,
  ) {
    InvoiceSuggestion? best;
    for (final item in results) {
      if (!InvoiceHelper.prefixesMatch(item.prefix, prefix)) continue;
      if (best == null || _statePriority(item) > _statePriority(best)) {
        best = item;
      }
    }
    return best;
  }

  int _statePriority(InvoiceSuggestion suggestion) {
    if (suggestion.isPaid) return 4;

    final payment = suggestion.paymentState?.toLowerCase().trim();
    if (payment == 'paid' || payment == 'in_payment') return 4;

    switch (suggestion.state.toLowerCase().trim()) {
      case 'paid':
        return 4;
      case 'posted':
      case 'open':
        return 3;
      case 'draft':
        return 1;
      default:
        return 0;
    }
  }

  Color _statusColor(InvoiceSuggestion suggestion) {
    if (suggestion.isPaid) return Colors.redAccent;
    if (!suggestion.isDraft) return Colors.orangeAccent;
    return Colors.lightGreenAccent;
  }

  void _selectSuggestion(InvoiceSuggestion suggestion) {
    widget.controller.text = suggestion.prefix;
    setState(() {
      _suggestions = [];
      _matchedSuggestion = suggestion;
      _showPanel = false;
    });
    _focusNode.unfocus();

    if (widget.warnOnNonDraftSelection &&
        !suggestion.isDraft &&
        suggestion.warningMessage.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        StatusDialog.show(
          context: context,
          title: 'Warning',
          message: suggestion.warningMessage,
          type: StatusType.info,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final yearSuffix = InvoiceHelper.yearSuffix();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                style: const TextStyle(
                  fontSize: 17,
                  color: sectionText,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.hintText,
                  hintStyle: const TextStyle(color: sectionTextMuted),
                  border: const UnderlineInputBorder(),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                      color: sectionCardBorder,
                    ),
                  ),
                  focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: const Color(0xFFE07A2F)),
                  ),
                ),
                onTap: () {
                  if (widget.controller.text.trim().isNotEmpty) {
                    setState(() => _showPanel = true);
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 2),
              child: Text(
                '/$yearSuffix',
                style: const TextStyle(
                  fontSize: 17,
                  color: sectionTextMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (widget.warnOnNonDraftSelection && _matchedSuggestion != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Bill status: ${_matchedSuggestion!.statusLabel}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _statusColor(_matchedSuggestion!),
              ),
            ),
          ),
        if (_showPanel && (_loading || _suggestions.isNotEmpty || _searchedWithNoResults))
          _SuggestionsPanel(
            loading: _loading,
            suggestions: _suggestions,
            yearSuffix: yearSuffix,
            noResults: _searchedWithNoResults,
            showStatus: widget.warnOnNonDraftSelection,
            onSelected: _selectSuggestion,
          ),
      ],
    );
  }
}

class _SuggestionsPanel extends StatelessWidget {
  const _SuggestionsPanel({
    required this.loading,
    required this.suggestions,
    required this.yearSuffix,
    required this.noResults,
    required this.showStatus,
    required this.onSelected,
  });

  final bool loading;
  final List<InvoiceSuggestion> suggestions;
  final String yearSuffix;
  final bool noResults;
  final bool showStatus;
  final ValueChanged<InvoiceSuggestion> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2638),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFE07A2F).withValues(alpha: 0.55),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: const Color(0xFFE07A2F),
                  ),
                ),
              ),
            )
          : noResults
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text(
                showStatus
                    ? 'No matching invoices found'
                    : 'No draft invoices found',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 15,
                ),
              ),
            )
          : ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: suggestions.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: Colors.white.withValues(alpha: 0.12),
              ),
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                final statusColor = suggestion.isPaid
                    ? Colors.redAccent.withValues(alpha: 0.9)
                    : suggestion.isDraft
                    ? Colors.greenAccent.withValues(alpha: 0.85)
                    : Colors.orangeAccent.withValues(alpha: 0.9);
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => onSelected(suggestion),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.receipt_long,
                            size: 18,
                            color: const Color(0xFFE07A2F).withValues(alpha: 0.9),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${suggestion.prefix}/$yearSuffix',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (showStatus) ...[
                            const SizedBox(width: 8),
                            Text(
                              suggestion.statusLabel,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
