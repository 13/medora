/// Medora - Entering the Supabase project URL and key at runtime.
///
/// The key is stored in `SharedPreferences` only; it is never logged and,
/// once saved, never shown again — the sheet offers to replace it instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/settings_providers.dart';

/// What the sheet was closed with.
enum CloudConfigOutcome {
  /// Credentials were saved and cloud sync works right away.
  savedAndActive,

  /// Credentials were saved, but Supabase is already running with the old
  /// ones: the app has to restart.
  savedNeedsRestart,

  /// The user asked to forget the stored credentials. The caller decides what
  /// that means for the data on the device.
  clearRequested,
}

/// Shows the cloud configuration sheet; returns null when it is dismissed.
Future<CloudConfigOutcome?> showCloudConfigSheet(BuildContext context) =>
    showModalBottomSheet<CloudConfigOutcome>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const CloudConfigSheet(),
    );

class CloudConfigSheet extends ConsumerStatefulWidget {
  const CloudConfigSheet({super.key});

  static const urlFieldKey = Key('cloud-config-url');
  static const keyFieldKey = Key('cloud-config-key');

  @override
  ConsumerState<CloudConfigSheet> createState() => _CloudConfigSheetState();
}

enum _ProbeState { idle, running, reachable, unreachable }

class _CloudConfigSheetState extends ConsumerState<CloudConfigSheet> {
  late final TextEditingController _url;
  final _key = TextEditingController();

  /// True while a previously saved key is kept as-is (masked).
  late bool _keepStoredKey;
  String? _urlError;
  String? _keyError;
  _ProbeState _probe = _ProbeState.idle;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final stored = ref.read(cloudCredentialsProvider);
    _url = TextEditingController(text: stored?.url ?? '');
    _keepStoredKey = stored != null;
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  /// The credentials as they stand, reusing the stored key when untouched.
  CloudCredentials get _current => CloudCredentials(
    url: _url.text,
    anonKey: _keepStoredKey
        ? ref.read(cloudCredentialsProvider)?.anonKey ?? ''
        : _key.text,
  );

  bool _validate(AppLocalizations l10n) {
    final credentials = _current;
    setState(() {
      _urlError = CloudCredentials.isValidUrl(credentials.url)
          ? null
          : l10n.cloudInvalidUrl;
      _keyError = credentials.normalizedKey.isEmpty
          ? l10n.cloudKeyRequired
          : null;
    });
    return _urlError == null && _keyError == null;
  }

  Future<void> _test(AppLocalizations l10n) async {
    if (!_validate(l10n)) return;
    setState(() => _probe = _ProbeState.running);
    bool reachable;
    try {
      reachable = await probeCloudCredentials(
        ref.read(cloudHttpClientProvider),
        _current,
      );
    } catch (_) {
      // Any transport failure reads the same to the user: not reachable.
      reachable = false;
    }
    if (!mounted) return;
    setState(
      () =>
          _probe = reachable ? _ProbeState.reachable : _ProbeState.unreachable,
    );
  }

  Future<void> _save(AppLocalizations l10n) async {
    if (!_validate(l10n) || _saving) return;
    setState(() => _saving = true);
    final credentials = _current.normalized;
    await ref.read(cloudCredentialsProvider.notifier).save(credentials);
    final active = await ref.read(cloudActivatorProvider)(credentials);
    if (!mounted) return;
    Navigator.pop(
      context,
      active
          ? CloudConfigOutcome.savedAndActive
          : CloudConfigOutcome.savedNeedsRestart,
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _keepStoredKey = false;
      _key.text = text;
      _keyError = null;
      _probe = _ProbeState.idle;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stored = ref.watch(cloudCredentialsProvider);
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.configureCloud, style: text.titleLarge),
            const SizedBox(height: 8),
            Text(
              l10n.cloudConfigIntro,
              style: text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: CloudConfigSheet.urlFieldKey,
              controller: _url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.cloudProjectUrl,
                hintText: l10n.cloudProjectUrlHint,
                errorText: _urlError,
                prefixIcon: const Icon(Icons.link),
              ),
              onChanged: (_) => setState(() {
                _urlError = null;
                _probe = _ProbeState.idle;
              }),
            ),
            const SizedBox(height: 16),
            if (_keepStoredKey)
              _StoredKeyRow(
                onReplace: () => setState(() {
                  _keepStoredKey = false;
                  _probe = _ProbeState.idle;
                }),
              )
            else
              TextField(
                key: CloudConfigSheet.keyFieldKey,
                controller: _key,
                autocorrect: false,
                obscureText: true,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.cloudAnonKey,
                  errorText: _keyError,
                  prefixIcon: const Icon(Icons.key),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste),
                    tooltip: l10n.paste,
                    onPressed: _paste,
                  ),
                ),
                onChanged: (_) => setState(() {
                  _keyError = null;
                  _probe = _ProbeState.idle;
                }),
              ),
            if (_keepStoredKey && _keyError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _keyError!,
                  style: text.bodySmall?.copyWith(color: context.colors.error),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _probe == _ProbeState.running
                      ? null
                      : () => _test(l10n),
                  icon: _probe == _ProbeState.running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check),
                  label: Text(l10n.cloudTestConnection),
                ),
              ],
            ),
            if (_probe == _ProbeState.reachable ||
                _probe == _ProbeState.unreachable)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _probe == _ProbeState.reachable
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 18,
                      color: _probe == _ProbeState.reachable
                          ? context.medora.success
                          : context.colors.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _probe == _ProbeState.reachable
                            ? l10n.cloudTestOk
                            : l10n.cloudTestFailed,
                        style: text.bodySmall?.copyWith(
                          color: _probe == _ProbeState.reachable
                              ? context.medora.success
                              : context.colors.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (stored != null)
                  TextButton(
                    onPressed: () => Navigator.pop(
                      context,
                      CloudConfigOutcome.clearRequested,
                    ),
                    child: Text(
                      l10n.clear,
                      style: TextStyle(color: context.colors.error),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : () => _save(l10n),
                  child: Text(l10n.save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A saved key is never shown again — only replaced.
class _StoredKeyRow extends StatelessWidget {
  const _StoredKeyRow({required this.onReplace});

  final VoidCallback onReplace;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: l10n.cloudAnonKey,
        helperText: l10n.cloudKeyStored,
        prefixIcon: const Icon(Icons.key),
      ),
      child: Row(
        children: [
          const Expanded(child: Text('••••••••')),
          TextButton(onPressed: onReplace, child: Text(l10n.cloudKeyReplace)),
        ],
      ),
    );
  }
}
