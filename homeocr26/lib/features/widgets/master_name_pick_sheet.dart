import 'package:flutter/material.dart';

import '../theme.dart';

/// Searchable pick/create sheet used by stock (same interaction as
/// Customer Invoice potency / company / pack / group / rack dropdowns).
class MasterNamePickSheet {
  const MasterNamePickSheet._();

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required List<String> options,
    String? selected,
    bool allowCreate = true,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: dark ? stockCard : sectionBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _MasterNamePickBody(
        title: title,
        options: options,
        selected: selected,
        allowCreate: allowCreate,
        dark: dark,
      ),
    );
  }
}

class _MasterNamePickBody extends StatefulWidget {
  const _MasterNamePickBody({
    required this.title,
    required this.options,
    required this.allowCreate,
    required this.dark,
    this.selected,
  });

  final String title;
  final List<String> options;
  final String? selected;
  final bool allowCreate;
  final bool dark;

  @override
  State<_MasterNamePickBody> createState() => _MasterNamePickBodyState();
}

class _MasterNamePickBodyState extends State<_MasterNamePickBody> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.selected ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.dark ? stockText : sectionText;
    final muted = widget.dark ? stockTextMuted : sectionTextMuted;
    final fill = widget.dark
        ? Colors.black.withValues(alpha: 0.28)
        : sectionCard;
    final query = _controller.text.trim();
    final q = query.toLowerCase();
    final filtered = widget.options
        .where((name) => q.isEmpty || name.toLowerCase().contains(q))
        .toList(growable: false);
    final canCreate = widget.allowCreate &&
        query.isNotEmpty &&
        !widget.options.any((name) => name.toLowerCase() == q);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  autofocus: true,
                  controller: _controller,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(color: textColor, fontSize: 16),
                  cursorColor: sectionAccent,
                  decoration: InputDecoration(
                    hintText: widget.allowCreate
                        ? 'Search or type to create…'
                        : 'Search…',
                    hintStyle: TextStyle(color: muted),
                    prefixIcon: Icon(Icons.search, color: muted),
                    filled: true,
                    fillColor: fill,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              if (canCreate)
                ListTile(
                  leading: const Icon(Icons.add, color: sectionAccent),
                  title: Text(
                    'Create "$query"',
                    style: const TextStyle(
                      color: sectionAccent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onTap: () => Navigator.pop(context, query),
                ),
              ListTile(
                title: Text('Clear selection', style: TextStyle(color: muted)),
                onTap: () => Navigator.pop(context, ''),
              ),
              Divider(color: muted.withValues(alpha: 0.3)),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          canCreate ? 'No matches — create above' : 'No matches',
                          style: TextStyle(color: muted),
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final name = filtered[i];
                          final isSelected = (widget.selected ?? '')
                                  .toLowerCase() ==
                              name.toLowerCase();
                          return ListTile(
                            title: Text(name, style: TextStyle(color: textColor)),
                            trailing: isSelected
                                ? const Icon(Icons.check, color: sectionAccent)
                                : null,
                            onTap: () => Navigator.pop(context, name),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
