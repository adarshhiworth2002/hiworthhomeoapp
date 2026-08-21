import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared search field for list screens (first-letter / prefix filter).
class ListSearchField extends StatelessWidget {
  const ListSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hintText = 'Search…',
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: sectionText, fontSize: 16),
      cursorColor: sectionAccent,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: sectionTextMuted),
        prefixIcon: const Icon(Icons.search, color: sectionAccent),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
                icon: const Icon(Icons.clear, color: sectionTextMuted),
              ),
        filled: true,
        fillColor: sectionCard,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: sectionCardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: sectionCardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: sectionAccent),
        ),
      ),
    );
  }
}
