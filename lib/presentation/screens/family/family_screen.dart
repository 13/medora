/// Medora - Family Sharing Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/family_member.dart';
import 'package:medora/presentation/providers/family_providers.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:share_plus/share_plus.dart';

class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final familyAsync = ref.watch(currentFamilyProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.familySharingTitle)),
      body: familyAsync.when(
        data: (family) {
          if (family == null) {
            return _NoFamilyView();
          }
          return _FamilyDetailView(family: family);
        },
        loading: () => LoadingWidget(message: l10n.loadingFamily),
        error: (e, _) => ErrorDisplayWidget(
          message: e.toString(),
          onRetry: () =>
              ref.read(currentFamilyProvider.notifier).refresh(),
        ),
      ),
    );
  }
}

class _NoFamilyView extends ConsumerStatefulWidget {
  @override
  ConsumerState<_NoFamilyView> createState() => _NoFamilyViewState();
}

class _NoFamilyViewState extends ConsumerState<_NoFamilyView> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline,
                size: 80, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              l10n.noFamilyGroup,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.noFamilyDescription,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () => _showCreateDialog(context),
                icon: const Icon(Icons.group_add),
                label: Text(l10n.createFamily),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => _showJoinDialog(context),
                icon: const Icon(Icons.link),
                label: Text(l10n.joinWithCode),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final nameCtrl = TextEditingController();
    final displayCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.createFamily),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: l10n.familyName,
                hintText: l10n.familyNameHint,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: displayCtrl,
              decoration: InputDecoration(
                labelText: l10n.yourName,
                hintText: l10n.yourNameHint,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty ||
                  displayCtrl.text.trim().isEmpty) {
                return;
              }
              ref.read(currentFamilyProvider.notifier).createFamily(
                    nameCtrl.text.trim(),
                    displayCtrl.text.trim(),
                  );
              Navigator.pop(ctx);
            },
            child: Text(l10n.create),
          ),
        ],
      ),
    );
  }

  void _showJoinDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final codeCtrl = TextEditingController();
    final displayCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.joinFamily),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeCtrl,
              decoration: InputDecoration(
                labelText: l10n.inviteCode,
                hintText: l10n.inviteCodeHint,
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: displayCtrl,
              decoration: InputDecoration(
                labelText: l10n.yourName,
                hintText: l10n.yourNameHint,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (codeCtrl.text.trim().isEmpty ||
                  displayCtrl.text.trim().isEmpty) {
                return;
              }
              ref.read(currentFamilyProvider.notifier).joinFamily(
                    codeCtrl.text.trim().toUpperCase(),
                    displayCtrl.text.trim(),
                  );
              Navigator.pop(ctx);
            },
            child: Text(l10n.join),
          ),
        ],
      ),
    );
  }
}

class _FamilyDetailView extends ConsumerWidget {
  const _FamilyDetailView({required this.family});

  final dynamic family;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final membersAsync = ref.watch(familyMembersProvider(family.id as String));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Family info card
        Card(
          color: AppTheme.primaryColor.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 32,
                  backgroundColor: AppTheme.primaryColor,
                  child: Icon(Icons.people, size: 32, color: Colors.white),
                ),
                const SizedBox(height: 12),
                Text(
                  family.name as String,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Invite code card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.inviteCode,
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Text(
                          (family.inviteCode as String?) ?? '------',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: l10n.copyCode,
                      onPressed: () {
                        final code = family.inviteCode as String?;
                        if (code != null) {
                          Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.codeCopied)),
                          );
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.share),
                      tooltip: l10n.shareCode,
                      onPressed: () {
                        final code = family.inviteCode as String?;
                        if (code != null) {
                          SharePlus.instance.share(
                            ShareParams(
                              text: l10n.joinMedoraFamily(code),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => ref
                      .read(currentFamilyProvider.notifier)
                      .regenerateCode(),
                  child: Text(l10n.generateNewCode),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Members
        Text(
          l10n.members,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),

        membersAsync.when(
          data: (members) {
            if (members.isEmpty) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.noMembersYet),
                ),
              );
            }
            return Column(
              children: members.map((m) {
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: m.role == FamilyRole.owner
                          ? AppTheme.primaryColor
                          : Colors.grey,
                      child: Text(
                        (m.displayName ?? '?')[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(m.displayName ?? l10n.unknown),
                    subtitle: Text(
                        m.role == FamilyRole.owner ? l10n.owner : l10n.member),
                    trailing: m.role == FamilyRole.owner
                        ? const Icon(Icons.star, color: Colors.amber)
                        : IconButton(
                            icon: const Icon(Icons.remove_circle_outline,
                                color: Colors.red),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text(l10n.removeMember),
                                  content: Text(
                                      l10n.removeMemberConfirm(m.displayName ?? l10n.unknown)),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: Text(l10n.cancel),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, true),
                                      child: Text(l10n.remove,
                                          style:
                                              const TextStyle(color: Colors.red)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                final repo =
                                    ref.read(familyRepositoryProvider);
                                await repo.removeMember(m.id);
                                ref.invalidate(
                                    familyMembersProvider(family.id as String));
                              }
                            },
                          ),
                  ),
                );
              }).toList(),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
        ),

        const SizedBox(height: 32),

        // Leave family button
        OutlinedButton.icon(
          onPressed: () async {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(l10n.leaveFamily),
                content: Text(l10n.leaveFamilyConfirm),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l10n.cancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l10n.leave,
                        style: const TextStyle(color: Colors.red)),
                  ),
                ],
              ),
            );
            if (confirm == true) {
              ref.read(currentFamilyProvider.notifier).leaveFamily();
            }
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            side: const BorderSide(color: Colors.red),
          ),
          icon: const Icon(Icons.logout),
          label: Text(l10n.leaveFamily),
        ),
      ],
    );
  }
}

