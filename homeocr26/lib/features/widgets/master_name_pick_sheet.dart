import 'dart:async';

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
    /// Optional live search (e.g. medicine masters + stock) when typing.
    Future<List<String>> Function(String query)? onRemoteSearch,
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
        onRemoteSearch: onRemoteSearch,
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
    this.onRemoteSearch,
  });

  final String title;
  final List<String> options;
  final String? selected;
  final bool allowCreate;
  final bool dark;
  final Future<List<String>> Function(String query)? onRemoteSearch;

  @override
  State<_MasterNamePickBody> createState() => _MasterNamePickBodyState();
}

class _MasterNamePickBodyState extends State<_MasterNamePickBody> {
  late final TextEditingController _controller;
  Timer? _debounce;
  int _searchGen = 0;
  bool _searching = false;
  List<String> _remote = const [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.selected ?? '');
    if (widget.onRemoteSearch != null) {
      _scheduleRemote(_controller.text);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleRemote(String raw) {
    final search = widget.onRemoteSearch;
    if (search == null) return;
    _debounce?.cancel();
    final q = raw.trim();
    if (q.isEmpty) {
      setState(() {
        _remote = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final gen = ++_searchGen;
    _debounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final names = await search(q);
        if (!mounted || gen != _searchGen) return;
        setState(() {
          _remote = names;
          _searching = false;
        });
      } catch (_) {
        if (!mounted || gen != _searchGen) return;
        setState(() => _searching = false);
      }
    });
  }

  List<String> _merged(String query) {
    final q = query.toLowerCase();
    final seen = <String>{};
    final out = <String>[];
    void add(String name) {
      final t = name.trim();
      if (t.isEmpty) return;
      if (q.isNotEmpty && !t.toLowerCase().contains(q)) return;
      if (seen.add(t.toLowerCase())) out.add(t);
    }

    for (final name in widget.options) {
      add(name);
    }
    for (final name in _remote) {
      add(name);
    }
    out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
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
    final filtered = _merged(query);
    final canCreate = widget.allowCreate &&
        query.isNotEmpty &&
        !filtered.any((name) => name.toLowerCase() == q) &&
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
                    if (_searching)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
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
                  onChanged: (v) {
                    setState(() {});
                    _scheduleRemote(v);
                  },
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
                          _searching
                              ? 'Searching…'
                              : (canCreate
                                  ? 'No matches — create above'
                                  : 'No matches'),
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
