/// Medora - Shared tag input field (chips) for forms.
library;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// Reusable tag input field for entering multiple string tags as chips.
///
/// Type a value and press enter (or the add button) to add it; tap a
/// chip's delete icon to remove it. Duplicate tags are ignored.
class TagInputField extends StatefulWidget {
  const TagInputField({
    super.key,
    required this.label,
    required this.icon,
    required this.tags,
    required this.onChanged,
    this.hintText,
    this.isUserTag = false,
    this.suggestions = const <String>[],
  });

  final String label;
  final IconData icon;
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final String? hintText;
  final bool isUserTag;

  /// Optional quick-add suggestions shown below the field (e.g. recently
  /// used values). Tags already added are not repeated as suggestions.
  final List<String> suggestions;

  @override
  State<TagInputField> createState() => _TagInputFieldState();
}

class _TagInputFieldState extends State<TagInputField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  void _addTag(String text) {
    final tag = text.trim();
    if (tag.isNotEmpty && !widget.tags.contains(tag)) {
      widget.onChanged([...widget.tags, tag]);
    }
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final remainingSuggestions = widget.suggestions
        .where((s) => !widget.tags.contains(s))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: widget.tags.map((tag) {
                return InputChip(
                  label: TagChip(
                    label: tag,
                    fontSize: 12,
                    icon: widget.isUserTag ? Icons.person : null,
                  ),
                  deleteIcon: const Icon(Icons.cancel),
                  onDeleted: () {
                    widget.onChanged(
                      widget.tags.where((t) => t != tag).toList(),
                    );
                  },
                  backgroundColor: Colors.transparent,
                  side: BorderSide.none,
                  padding: EdgeInsets.zero,
                  labelPadding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: Icon(widget.icon),
            hintText: widget.hintText ?? l10n.addTag,
            suffixIcon: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _addTag(_controller.text),
            ),
          ),
          onSubmitted: (value) {
            _addTag(value);
            _focusNode.requestFocus();
          },
        ),
        if (remainingSuggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: remainingSuggestions.map((s) {
                return ActionChip(
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onPressed: () => _addTag(s),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}
