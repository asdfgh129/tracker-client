import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/common.dart';
import '../../../core/network/messaging_client.dart';
import '../../../core/storage/database.dart';
import '../../../domain/failures.dart';
import '../../../l10n/app_localizations.dart';
import '../application/friends_controller.dart';

/// 好友页（好友互见位置的核心入口）。
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final friends = ref.watch(friendsListProvider).valueOrNull ?? const [];
    final state = ref.watch(friendsControllerProvider);

    final pendingIn = friends.where((f) => f.status == 'pending_in').toList();
    final accepted = friends.where((f) => f.status == 'accepted').toList();
    final pendingOut = friends.where((f) => f.status == 'pending_out').toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.friendsTitle),
        actions: [
          IconButton(
            tooltip: l10n.friendsAdd,
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () => _showAddFriendDialog(l10n),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddFriendDialog(l10n),
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(l10n.friendsAdd),
      ),
      body: Column(
        children: [
          _ChannelBanner(status: state.channelStatus, error: state.channelError),
          if (state.pendingInvite != null)
            _InviteCard(invite: state.pendingInvite!),
          Expanded(
            child: friends.isEmpty
                ? EmptyState(
                    icon: Icons.group_outlined,
                    title: l10n.friendsEmpty,
                    subtitle: l10n.friendsEmptyHint,
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      for (final friend in pendingIn)
                        _FriendTile(friend: friend, highlighted: true),
                      for (final friend in accepted)
                        _FriendTile(friend: friend),
                      for (final friend in pendingOut)
                        _FriendTile(friend: friend),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddFriendDialog(AppLocalizations l10n) async {
    final controller = TextEditingController();
    final uniqueId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.friendsAddTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 12,
          decoration: InputDecoration(
            labelText: l10n.friendsAddHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (uniqueId == null || uniqueId.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final status =
          await ref.read(friendsControllerProvider.notifier).addFriend(uniqueId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            status == 'accepted'
                ? l10n.friendsAddedAccepted
                : l10n.friendsRequestSent,
          ),
        ),
      );
    } on AppFailure catch (error) {
      messenger.showSnackBar(
        SnackBar(
            content: Text('${l10n.friendsAddFailed}: ${error.userMessage}')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('${l10n.friendsAddFailed}: $error')),
      );
    }
  }
}

class _ChannelBanner extends StatelessWidget {
  const _ChannelBanner({required this.status, this.error});

  final MessagingStatus status;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (status == MessagingStatus.connected) {
      return const SizedBox.shrink();
    }
    final (text, color) = switch (status) {
      MessagingStatus.connecting ||
      MessagingStatus.authenticating =>
        (l10n.friendsChannelConnecting, theme.colorScheme.statusWarning),
      MessagingStatus.failed => (
          error ?? l10n.friendsChannelFailed,
          theme.colorScheme.error
        ),
      _ => (l10n.friendsChannelOffline, theme.colorScheme.statusNeutral),
    };
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }
}

class _InviteCard extends ConsumerWidget {
  const _InviteCard({required this.invite});

  final FriendInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.friendsPendingIn,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              invite.fromName?.isNotEmpty == true
                  ? '${invite.fromName}（${invite.fromUniqueId}）'
                  : invite.fromUniqueId,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => ref
                      .read(friendsControllerProvider.notifier)
                      .rejectInvite(),
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => ref
                      .read(friendsControllerProvider.notifier)
                      .acceptInvite(),
                  child: Text(l10n.friendsAccept),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendTile extends ConsumerStatefulWidget {
  const _FriendTile({required this.friend, this.highlighted = false});

  final FriendRow friend;
  final bool highlighted;

  @override
  ConsumerState<_FriendTile> createState() => _FriendTileState();
}

class _FriendTileState extends ConsumerState<_FriendTile> {
  bool _locating = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final friend = widget.friend;
    final name = (friend.name?.isNotEmpty ?? false) ? friend.name! : friend.uniqueId;
    final accepted = friend.status == 'accepted';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: widget.highlighted
          ? theme.colorScheme.primaryContainer
          : null,
      child: ListTile(
        leading: Stack(
          alignment: Alignment.bottomRight,
          children: [
            CircleAvatar(
              child: Text(
                friend.uniqueId.length > 2
                    ? friend.uniqueId.substring(0, 2)
                    : friend.uniqueId,
              ),
            ),
            if (accepted)
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: friend.online
                      ? theme.colorScheme.statusOnline
                      : theme.colorScheme.statusNeutral,
                ),
              ),
          ],
        ),
        title: Text(name, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              switch (friend.status) {
                'pending_in' => l10n.friendsPendingIn,
                'pending_out' => l10n.friendsPendingOut,
                _ =>
                  friend.online
                      ? l10n.friendsOnline
                      : l10n.friendsOffline,
              },
            ),
            if (accepted &&
                friend.lastLatitude != null &&
                friend.lastLongitude != null)
              Text(
                relativeTime(
                  l10n.timeJustNow,
                  l10n.timeSecondsAgo,
                  l10n.timeMinutesAgo,
                  l10n.timeHoursAgo,
                  l10n.timeDaysAgo,
                  friend.lastTime == null
                      ? null
                      : DateTime.fromMillisecondsSinceEpoch(
                          friend.lastTime!,
                          isUtc: true,
                        ),
                  DateTime.now(),
                ),
              ),
          ],
        ),
        trailing: _buildTrailing(context, l10n, friend, accepted, theme),
      ),
    );
  }

  Widget? _buildTrailing(
    BuildContext context,
    AppLocalizations l10n,
    FriendRow friend,
    bool accepted,
    ThemeData theme,
  ) {
    final controller = ref.read(friendsControllerProvider.notifier);
    if (widget.highlighted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => controller.rejectFriendById(friend.uniqueId),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => controller.acceptFriendById(friend.uniqueId),
            child: Text(l10n.friendsAccept),
          ),
        ],
      );
    }
    if (!accepted) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.tonal(
          onPressed: _locating
              ? null
              : () async {
                  setState(() => _locating = true);
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final result = await controller
                        .requestRealtimeLocation(friend.uniqueId);
                    messenger.showSnackBar(SnackBar(
                      content: Text(switch (result) {
                        'position' => l10n.friendsLocateResultPosition,
                        'timeout' => l10n.friendsLocateResultTimeout,
                        'declined' => l10n.friendsLocateResultDeclined,
                        'offline' => l10n.friendsLocateResultOffline,
                        _ => l10n.friendsLocateResultTimeout,
                      }),
                    ));
                  } on AppFailure catch (error) {
                    messenger.showSnackBar(SnackBar(
                      content: Text(
                          '${l10n.friendsLocateFailed}: ${error.userMessage}'),
                    ));
                  } finally {
                    if (mounted) setState(() => _locating = false);
                  }
                },
          child: _locating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.friendsLocate),
        ),
        IconButton(
          tooltip: l10n.friendsRemove,
          icon: const Icon(Icons.person_remove_outlined, size: 20),
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(l10n.friendsRemove),
                content: Text(l10n.friendsRemoveConfirm),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l10n.commonCancel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(l10n.commonConfirm),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await controller.removeFriend(friend.uniqueId);
            }
          },
        ),
      ],
    );
  }
}
