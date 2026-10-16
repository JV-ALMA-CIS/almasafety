import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'outbox.dart';

/// A slim coloured strip above every page, shown only when it matters:
/// no signal, entries saved on this phone waiting to send, or an entry the
/// server refused. Tapping it lists what is waiting. Nothing blocks — people
/// keep working underneath it.
class OutboxStatusBar extends StatelessWidget {
  OutboxStatusBar({super.key, required this.child, Outbox? outbox})
    : outbox = outbox ?? Outbox.instance;

  final Widget child;
  final Outbox outbox;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListenableBuilder(
          listenable: outbox,
          builder: (context, _) => _strip(context),
        ),
        Expanded(child: child),
      ],
    );
  }

  Widget _strip(BuildContext context) {
    final waiting = outbox.waiting.length;
    final failed = outbox.failed.length;
    final online = outbox.isOnline;
    if (waiting == 0 && failed == 0 && online) return const SizedBox.shrink();

    final Color color;
    final IconData icon;
    final String text;
    if (failed > 0) {
      color = AppColors.danger;
      icon = Icons.error_outline;
      text = failed == 1
          ? '1 entry could not be sent - tap to see why'
          : '$failed entries could not be sent - tap to see why';
    } else if (waiting > 0) {
      color = AppColors.secondary;
      icon = Icons.cloud_upload_outlined;
      final entries = waiting == 1 ? '1 entry' : '$waiting entries';
      text = online
          ? '$entries saved on this phone - sending'
          : '$entries saved on this phone - will send when the signal '
                'comes back';
    } else {
      color = AppColors.secondary;
      icon = Icons.cloud_off;
      text =
          'No signal - keep working. Entries are saved on this phone and '
          'sent later.';
    }

    final onColor = failed > 0 ? Colors.white : AppColors.textPrimary;
    return Material(
      color: color,
      child: InkWell(
        onTap: waiting + failed > 0 ? () => showOutboxSheet(context) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            children: [
              Icon(icon, color: onColor, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  text,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: onColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (waiting > 0 && online)
                outbox.isSending
                    ? Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: onColor,
                          ),
                        ),
                      )
                    : TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: onColor,
                          minimumSize: const Size(0, 40),
                        ),
                        onPressed: outbox.flush,
                        child: const Text('Send now'),
                      ),
            ],
          ),
        ),
      ),
    );
  }

  /// Lists everything saved on this phone, with Try again / Remove for an
  /// entry the server refused.
  Future<void> showOutboxSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: outbox,
        builder: (context, _) {
          final entries = outbox.entries;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.md,
              ),
              children: [
                const Text(
                  'Saved on this phone',
                  style: AppTextStyles.titleLarge,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  entries.isEmpty
                      ? 'Everything has been sent.'
                      : 'These are sent automatically, oldest first, as soon '
                            'as there is signal. Keep the app open or open it '
                            'again later.',
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final entry in entries) _EntryTile(entry, outbox),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry, this.outbox);

  final OutboxEntry entry;
  final Outbox outbox;

  @override
  Widget build(BuildContext context) {
    final color = entry.failed ? AppColors.danger : AppColors.secondary;
    final t = entry.createdAt;
    final time =
        '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  entry.failed ? Icons.error_outline : Icons.schedule,
                  color: color,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '${entry.label}${entry.photo != null ? ' (with photo)' : ''}',
                    style: AppTextStyles.bodyLarge.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(time, style: AppTextStyles.label),
              ],
            ),
            if (entry.failed) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(entry.error!, style: AppTextStyles.bodyMedium),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: () => outbox.retry(entry.id),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      minimumSize: const Size(0, 40),
                    ),
                    onPressed: () => _confirmRemove(context),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(
          'Remove "${entry.label}" from this phone? It will not be sent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await outbox.remove(entry.id);
  }
}
