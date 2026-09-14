/// Medora - Consistent AsyncValue loading/empty/error handling.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// Renders an [AsyncValue] with consistent loading, empty and error states.
///
/// - `loading`: shown while [value] is loading; defaults to [LoadingWidget]
///   or a compact 3-line skeleton when [compact] is true.
/// - `emptyWhen`/`empty`: when [emptyWhen] returns true for the loaded data,
///   [empty] is shown instead of [data].
/// - error: shows a generic error message with an expandable "Details"
///   section revealing the raw error, and a Retry button when [onRetry] is
///   provided.
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
    this.loading,
    this.emptyWhen,
    this.empty,
    this.compact = false,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final Future<void> Function()? onRetry;
  final Widget? loading;
  final bool Function(T data)? emptyWhen;
  final Widget? empty;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      data: (d) {
        if (emptyWhen?.call(d) == true && empty != null) return empty!;
        return data(d);
      },
      loading: () =>
          loading ??
          (compact
              ? const Card(child: _CompactLoading())
              : const LoadingWidget()),
      error: (e, _) => _ErrorView(error: e, onRetry: onRetry, compact: compact),
    );
  }
}

/// Compact 3-line shimmer-less skeleton, used for card-sized loading states.
class _CompactLoading extends StatelessWidget {
  const _CompactLoading();

  @override
  Widget build(BuildContext context) {
    Widget bar(double widthFactor) => FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 12,
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bar(0.6),
          const SizedBox(height: 10),
          bar(0.9),
          const SizedBox(height: 10),
          bar(0.4),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.error,
    required this.onRetry,
    required this.compact,
  });

  final Object error;
  final Future<void> Function()? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, color: context.colors.error),
        const SizedBox(height: 8),
        Text(l10n.genericError, textAlign: TextAlign.center),
        Theme(
          data: Theme.of(
            context,
          ).copyWith(dividerColor: compact ? Colors.transparent : null),
          child: ExpansionTile(
            title: Text(l10n.details),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(error.toString()),
              ),
            ],
          ),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => onRetry!(),
            child: Text(l10n.retry),
          ),
        ],
      ],
    );

    if (!compact) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: content),
      );
    }

    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: content),
    );
  }
}
