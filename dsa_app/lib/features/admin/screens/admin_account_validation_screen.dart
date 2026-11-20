import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/services/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/widgets/profile_photo.dart';
import '../../../core/services/live_refresh.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class PendingAccount {
  final int id;
  final String name;
  final String username;
  final String email;
  final String? phone;

  const PendingAccount({
    required this.id,
    required this.name,
    required this.username,
    required this.email,
    this.phone,
  });

  factory PendingAccount.fromJson(Map<String, dynamic> json) => PendingAccount(
    id: int.parse(json['id'] as String),
    name: json['full_name'] as String,
    username: json['username'] as String,
    email: json['email'] as String,
    phone: json['phone'] as String?,
  );
}

/// Just the count, for the Home dashboard's summary card — avoids that
/// card needing to know anything about PendingAccount or pull the whole
/// list just to show a number.
///
/// Everything on this screen goes through ApiClient so it carries the login
/// token. It used to call the server directly without one, so after logins
/// became required no signup could be loaded or approved at all.
Future<int> fetchPendingAccountCount() async =>
    (await ApiClient.getList('/admin/pending-users')).length;

/// Newly created accounts (users.status = 'pending') awaiting admin
/// approval before they can log in — see /auth/login in dsa_server,
/// which refuses a pending account with "awaiting admin approval."
class AdminAccountValidation extends StatefulWidget {
  const AdminAccountValidation({super.key});

  @override
  State<AdminAccountValidation> createState() => _AdminAccountValidationState();
}

class _AdminAccountValidationState extends State<AdminAccountValidation>
    with LiveRefreshing<AdminAccountValidation> {
  @override
  Future<void> reloadQuietly() async {
    final rows = await ApiClient.getList('/admin/pending-users');
    _pending = rows
        .map((row) => PendingAccount.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  List<PendingAccount> _pending = [];
  bool _loading = true;
  String? _loadError;

  bool _searching = false;
  String _query = "";
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final rows = await ApiClient.getList('/admin/pending-users');
      _pending = rows
          .map((row) => PendingAccount.fromJson(row as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _loadError = "${friendlyError(e)}\nPull down to retry.";
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _query = "";
        _searchController.clear();
      }
    });
  }

  /// Accounts with a request in flight. A second tap on APPROVE used to send
  /// it again and come back as "No pending account with that id".
  final Set<int> _working = {};

  /// Asks first. Approving gives a stranger a login that can see the club's
  /// schedule and messages, and it sat right next to the account details, so
  /// a stray tap while reading one used to let them straight in.
  Future<void> _approve(PendingAccount account) async {
    final contact = [
      account.email,
      if (account.phone != null && account.phone!.trim().isNotEmpty)
        account.phone!,
    ].join(" · ");
    final confirmed = await showConfirmDialog(
      context,
      title: "Approve this account?",
      message:
          "${account.name} (@${account.username}, $contact) will be able to "
          "log in, add their children and see the academy's schedule and "
          "messages. Only approve people you know.",
      confirmLabel: "YES, APPROVE",
    );
    if (!confirmed || !mounted || !_working.add(account.id)) return;
    try {
      await ApiClient.post('/admin/users/${account.id}/approve');
      if (mounted) setState(() => _pending.remove(account));
    } catch (e) {
      _showError(friendlyError(e));
    } finally {
      _working.remove(account.id);
    }
  }

  /// Asks first: deleting a signup can't be undone, and it sat one tap
  /// below APPROVE.
  Future<void> _delete(PendingAccount account) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Delete this signup?",
      message:
          "${account.name} (@${account.username}) won't be able to log in, "
          "and would have to sign up again.",
      confirmLabel: "DELETE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || !_working.add(account.id)) return;
    try {
      await ApiClient.delete('/admin/users/${account.id}');
      if (mounted) setState(() => _pending.remove(account));
    } catch (e) {
      _showError(friendlyError(e));
    } finally {
      _working.remove(account.id);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  List<PendingAccount> get _filtered {
    if (_query.isEmpty) return _pending;
    final q = _query.toLowerCase();
    return _pending
        .where(
          // The name too: it's what each row shows first.
          (a) =>
              a.name.toLowerCase().contains(q) ||
              a.username.toLowerCase().contains(q) ||
              a.email.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _filtered;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: _searching
                        ? TextField(
                            controller: _searchController,
                            autofocus: true,
                            onChanged: (v) => setState(() => _query = v),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            decoration: const InputDecoration(
                              hintText: "Search name, username or email...",
                              hintStyle: TextStyle(color: Colors.white38),
                              isDense: true,
                              border: InputBorder.none,
                            ),
                          )
                        : const Text(
                            "ACCOUNT VALIDATION",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                  ),
                  IconButton(
                    onPressed: _toggleSearch,
                    icon: Icon(
                      _searching ? Icons.close : Icons.search,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                color: _accent,
                backgroundColor: _card,
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: _accent),
                      )
                    : _loadError != null
                    ? ListView(
                        // A scrollable single child so pull-to-refresh
                        // still works even while showing the error.
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.6,
                            child: Center(
                              child: Text(
                                _loadError!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.amber,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : accounts.isEmpty
                    ? ListView(
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.6,
                            child: Center(
                              child: Text(
                                _pending.isEmpty
                                    ? "No accounts awaiting approval."
                                    : "No accounts match.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: accounts.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final account = accounts[index];
                          return FadeSlideIn(
                            index: index,
                            child: _PendingAccountRow(
                              account: account,
                              onApprove: () => _approve(account),
                              onDelete: () => _delete(account),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingAccountRow extends StatelessWidget {
  final PendingAccount account;
  final VoidCallback onApprove;
  final VoidCallback onDelete;

  const _PendingAccountRow({
    required this.account,
    required this.onApprove,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Not approved yet, so no photo: the same round default every
          // other list shows.
          const ProfilePhoto(radius: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "@${account.username}",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
                Text(
                  account.email,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
                if (account.phone != null && account.phone!.isNotEmpty)
                  Text(
                    account.phone!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ActionButton(label: "APPROVE", color: _accent, onTap: onApprove),
              const SizedBox(height: 6),
              _ActionButton(
                label: "DELETE",
                color: Colors.redAccent,
                onTap: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 84,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
