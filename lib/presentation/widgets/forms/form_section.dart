/// Medora - Collapsible form section card.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';

/// A [Card] with a tappable header (icon, title, optional collapsed
/// [summary], chevron) and an animated collapsible body.
///
/// Expansion is normally driven by the header tap, but a parent can also
/// drive it programmatically — e.g. to force the section open to reveal a
/// field that failed validation, or to start an edit-mode section open when
/// it already has data — by passing a [controller]. The sync is two-way: a
/// header tap writes the new expanded state back to the controller, and
/// setting the controller's value (to either `true` or `false`) expands or
/// collapses the section. This keeps a controller-driven force-expand
/// working even after the user has manually collapsed the section.
class FormSection extends StatefulWidget {
  const FormSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.initiallyExpanded = true,
    this.summary,
    this.controller,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool initiallyExpanded;

  /// Shown next to the chevron while the section is collapsed.
  final String? summary;

  /// When provided, keeps the section's expanded state in sync with this
  /// notifier in both directions: setting it forces the section open or
  /// closed, and a manual header tap writes the new state back into it.
  final ValueNotifier<bool>? controller;

  @override
  State<FormSection> createState() => _FormSectionState();
}

class _FormSectionState extends State<FormSection> {
  late bool _expanded = widget.controller?.value ?? widget.initiallyExpanded;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant FormSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onControllerChanged);
      widget.controller?.addListener(_onControllerChanged);
      _onControllerChanged();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final controller = widget.controller;
    if (controller == null) return;
    final v = controller.value;
    if (v != _expanded) {
      setState(() => _expanded = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            onTap: () {
              setState(() => _expanded = !_expanded);
              widget.controller?.value = _expanded;
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(widget.icon, color: context.colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: context.text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!_expanded && widget.summary != null) ...[
                    Flexible(
                      child: Text(
                        widget.summary!,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: Visibility(
              visible: _expanded,
              maintainState: true,
              maintainAnimation: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: widget.children,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
