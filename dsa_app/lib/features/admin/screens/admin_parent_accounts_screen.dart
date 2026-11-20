import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import '../../../core/services/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../../../core/utils/text_rules.dart';
import '../models/admin_player.dart';
import '../models/mock_announcements.dart';
import '../models/mock_roster.dart';
import '../models/payment_record.dart';
import '../../../core/widgets/option_pill.dart';
import '../../../core/widgets/option_sheet.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// One parent account that has been let in.
class ParentAccount {
  final int id;
  final String name;
  final String username;
  final String email;
  final String? phone;
  final bool disabled;

  /// Where their account photo loads from, or null.
  final String? photoUrl;

  /// Their password was reset and they haven't chosen a new one yet.
  final bool mustChangePassword;
  final int children;

  /// When the account was created (signed up), for sorting.
  final DateTime? joined;

  const ParentAccount({
    required this.id,
    required this.name,
    required this.username,
    required this.email,
    this.phone,
    required this.disabled,
    this.photoUrl,
    required this.mustChangePassword,
    required this.children,
    this.joined,
  });

  factory ParentAccount.fromJson(Map<String, dynamic> json) => ParentAccount(
    id: asInt(json['id']),
    name: json['full_name'] as String,
    username: json['username'] as String,
    email: json['email'] as String,
    phone: json['phone'] as String?,
    disabled: json['status'] == 'disabled',
    photoUrl: json['photo_url'] as String?,
    mustChangePassword: '${json['must_change_password']}' == '1',
    children: asInt(json['children']),
    joined: DateTime.tryParse('${json['created_at'] ?? ''}'),
  );
}

/// Every approved parent account. Tapping one opens its window: the
/// account's details, every child on it (each can be removed), and
/// deactivate / reactivate. An approved account could never be switched off
/// before, however long ago the family left.
///
/// Password resets are deliberately not here: they'll go by email once an
/// email service is set up, rather than through the admin.
class AdminParentAccounts extends StatefulWidget {
  const AdminParentAccounts({super.key});

  @override
  State<AdminParentAccounts> createState() => _AdminParentAccountsState();
}

class _AdminParentAccountsState extends State<AdminParentAccounts>
    with LiveRefreshing<AdminParentAccounts> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    _setAccounts(await ApiClient.getList('/admin/parents'));
  }

  List<ParentAccount> _accounts = [];
  bool _loading = true;
  String _search = "";

  /// Which accounts show, and in what order, on top of the search.
  String _filter = _filterOptions.first;
  String _sort = _sortOptions.first;

  Future<void> _pickFilter() async {
    final picked = await showOptionSheet(
      context,
      title: "SHOW ACCOUNTS",
      options: _filterOptions,
      selected: _filter,
    );
    if (picked != null) setState(() => _filter = picked);
  }

  Future<void> _pickSort() async {
    final picked = await showOptionSheet(
      context,
      title: "SORT ACCOUNTS",
      options: _sortOptions,
      selected: _sort,
    );
    if (picked != null) setState(() => _sort = picked);
  }

  /// The accounts matching the search and filter, in the chosen order.
  List<ParentAccount> _shown() {
    final needle = _search.trim().toLowerCase();
    final list = _accounts.where((a) {
      final matchesSearch =
          needle.isEmpty ||
          a.name.toLowerCase().contains(needle) ||
          a.username.toLowerCase().contains(needle) ||
          a.email.toLowerCase().contains(needle) ||
          (a.phone ?? '').contains(needle);
      final matchesFilter = switch (_filter) {
        "Active" => !a.disabled,
        "Deactivated" => a.disabled,
        "With children" => a.children > 0,
        "No children" => a.children == 0,
        "Password not changed yet" => a.mustChangePassword,
        _ => true,
      };
      return matchesSearch && matchesFilter;
    }).toList();
    int byName(ParentAccount a, ParentAccount b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    // Unknown join dates go last, whichever way it's sorted.
    int joinedOrder(ParentAccount a, ParentAccount b, {required bool newest}) {
      final x = a.joined, y = b.joined;
      if (x == null || y == null) {
        return x == y ? byName(a, b) : (x == null ? 1 : -1);
      }
      final c = newest ? y.compareTo(x) : x.compareTo(y);
      return c != 0 ? c : byName(a, b);
    }

    list.sort(switch (_sort) {
      "Name Z–A" => (a, b) => byName(b, a),
      "Newest first" => (a, b) => joinedOrder(a, b, newest: true),
      "Oldest first" => (a, b) => joinedOrder(a, b, newest: false),
      "Most children" => (a, b) {
        final c = b.children.compareTo(a.children);
        return c != 0 ? c : byName(a, b);
      },
      _ => byName,
    });
    return list;
  }

  /// Accounts with a request in flight, so a double tap can't send it twice.
  final Set<int> _working = {};

  /// Picking several families to message at once: the message icon at the
  /// top right turns it on, each tile gets a tick box, and ADD MESSAGE at
  /// the bottom writes one message to all of them.
  bool _selecting = false;
  final Set<int> _selected = {};

  void _setAccounts(List<dynamic> rows) {
    _accounts = [
      for (final row in rows)
        ParentAccount.fromJson(row as Map<String, dynamic>),
    ];
    // A family deactivated or deleted from another phone can't stay ticked:
    // they can't sign in to read it, and the server would refuse the lot.
    _selected.removeWhere(
      (id) => !_accounts.any((a) => a.id == id && !a.disabled),
    );
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selected.clear();
    });
  }

  void _toggleSelected(ParentAccount account) {
    if (account.disabled) {
      _showMessage(
        "${account.name}'s account is deactivated, so they can't sign in "
        "to read a message.",
      );
      return;
    }
    setState(() {
      if (!_selected.remove(account.id)) _selected.add(account.id);
    });
  }

  Future<void> _messageSelected() async {
    final picked = [
      for (final a in _accounts)
        if (_selected.contains(a.id)) a,
    ];
    if (picked.isEmpty) return;
    final sent = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _SendMessageDialog(accounts: picked),
    );
    if (sent == true && mounted) {
      setState(() {
        _selecting = false;
        _selected.clear();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      await loadPlayers();
      _setAccounts(await ApiClient.getList('/admin/parents'));
    } catch (e) {
      _showMessage(friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// The account's own window rather than a two-line menu: who it is, the
  /// children on it (each removable), and deactivate / reactivate.
  Future<void> _openActions(ParentAccount account) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _AccountDialog(
        account: account,
        onDeactivate: () => _deactivate(account),
        onReactivate: () => _reactivate(account),
      ),
    );
    // A child removed from inside the window changes the count on the tile.
    await _refresh();
  }

  Future<bool> _deactivate(ParentAccount account) async {
    final kids = account.children;
    final confirmed = await showConfirmDialog(
      context,
      title: "Deactivate ${account.name}?",
      message:
          "@${account.username} won't be able to log in, and any device "
          "they're signed in on is signed out now."
          "${kids > 0 ? "\n\nTheir ${kids == 1 ? 'child stays' : '$kids children stay'} "
                    "on any rosters, and bills and history are kept. If the "
                    "family has left, remove ${kids == 1 ? 'the child' : 'the children'} "
                    "from Players too." : ""}"
          "\n\nYou can reactivate the account at any time.",
      confirmLabel: "DEACTIVATE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || !mounted || !_working.add(account.id)) return false;
    try {
      await ApiClient.post('/admin/users/${account.id}/deactivate');
      _showMessage("${account.name} has been deactivated.");
      return true;
    } catch (e) {
      _showMessage(friendlyError(e));
      return false;
    } finally {
      _working.remove(account.id);
    }
  }

  Future<bool> _reactivate(ParentAccount account) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Reactivate ${account.name}?",
      message:
          "@${account.username} will be able to log in again with their "
          "existing password.",
      confirmLabel: "REACTIVATE",
    );
    if (!confirmed || !mounted || !_working.add(account.id)) return false;
    try {
      await ApiClient.post('/admin/users/${account.id}/reactivate');
      _showMessage("${account.name} can log in again.");
      return true;
    } catch (e) {
      _showMessage(friendlyError(e));
      return false;
    } finally {
      _working.remove(account.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown();

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: Text(
          _selecting ? "SELECT FAMILIES" : "PARENT ACCOUNTS",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _accounts.isEmpty ? null : _toggleSelecting,
            tooltip: _selecting ? "Cancel" : "Message several families",
            icon: Icon(
              _selecting ? Icons.close : Icons.mail_outline,
              color: Colors.white,
            ),
          ),
        ],
      ),
      // Only once at least one family is ticked.
      bottomNavigationBar: _selecting && _selected.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: _messageSelected,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(
                      Icons.mail_outline,
                      color: Colors.white,
                      size: 20,
                    ),
                    label: Text(
                      "ADD MESSAGE (${_selected.length})",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                cursorColor: _accent,
                decoration: InputDecoration(
                  hintText: "Search by name, username, email or phone",
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(Icons.search, color: Colors.white38),
                  isDense: true,
                  filled: true,
                  fillColor: _card,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Flexible(
                    child: OptionPill(
                      icon: Icons.filter_list,
                      label: "Show: $_filter",
                      onTap: _pickFilter,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: OptionPill(
                      icon: Icons.sort,
                      label: "Sort: $_sort",
                      onTap: _pickSort,
                    ),
                  ),
                ],
              ),
            ),
            if (_selecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selected.isEmpty
                            ? "Tick the families to message."
                            : "${_selected.length} "
                                  "${_selected.length == 1 ? 'family' : 'families'} "
                                  "selected",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    // Every active family in the list as it's filtered now.
                    Builder(
                      builder: (context) {
                        final active = [
                          for (final a in shown)
                            if (!a.disabled) a.id,
                        ];
                        final all =
                            active.isNotEmpty &&
                            active.every(_selected.contains);
                        return TextButton(
                          onPressed: active.isEmpty
                              ? null
                              : () => setState(() {
                                  if (all) {
                                    _selected.removeAll(active);
                                  } else {
                                    _selected.addAll(active);
                                  }
                                }),
                          child: Text(
                            all ? "CLEAR" : "SELECT ALL",
                            style: const TextStyle(
                              color: _accent,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      color: _accent,
                      child: shown.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                const SizedBox(height: 80),
                                Center(
                                  child: Text(
                                    _accounts.isEmpty
                                        ? "No parent accounts yet."
                                        : "No account matches that search "
                                              "or filter.",
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                              itemCount: shown.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) => FadeSlideIn(
                                index: index,
                                child: _AccountTile(
                                  account: shown[index],
                                  busy: _working.contains(shown[index].id),
                                  selecting: _selecting,
                                  selected: _selected.contains(shown[index].id),
                                  onTap: _selecting
                                      ? () => _toggleSelected(shown[index])
                                      : () => _openActions(shown[index]),
                                ),
                              ),
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final ParentAccount account;
  final bool busy;
  final VoidCallback onTap;

  /// Picking families to message: a tick box on the left, no menu dots.
  final bool selecting;
  final bool selected;

  const _AccountTile({
    required this.account,
    required this.busy,
    required this.onTap,
    this.selecting = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final contact = [
      account.email,
      if (account.phone != null && account.phone!.trim().isNotEmpty)
        account.phone!,
    ].join(" · ");
    return Pressable(
      enabled: !busy,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Opacity(
          opacity: account.disabled ? 0.6 : 1,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(14),
              border: selected
                  ? Border.all(color: _accent, width: 1.5)
                  : Border.all(color: Colors.transparent, width: 1.5),
            ),
            child: Row(
              children: [
                if (selecting) ...[
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Checkbox(
                      value: selected,
                      // Deactivated: can't sign in to read it.
                      onChanged: account.disabled ? null : (_) => onTap(),
                      activeColor: _accent,
                      checkColor: Colors.white,
                      side: const BorderSide(color: Colors.white38, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                account.disabled
                    ? const CircleAvatar(
                        radius: 22,
                        backgroundColor: Colors.white12,
                        child: Icon(
                          Icons.person_off_outlined,
                          color: Colors.white54,
                          size: 22,
                        ),
                      )
                    : ProfilePhoto(url: account.photoUrl, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              account.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (account.disabled) ...[
                            const SizedBox(width: 8),
                            const _Chip("DEACTIVATED", Colors.redAccent),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "@${account.username} · ${account.children} "
                        "${account.children == 1 ? 'child' : 'children'}",
                        style: const TextStyle(color: _accent, fontSize: 12),
                      ),
                      Text(
                        contact,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: _accent,
                          strokeWidth: 2,
                        ),
                      )
                    : selecting
                    ? const SizedBox.shrink()
                    : const Icon(Icons.more_vert, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// One parent account: details, children, and what the admin can do.
class _AccountDialog extends StatefulWidget {
  final ParentAccount account;
  final Future<bool> Function() onDeactivate;
  final Future<bool> Function() onReactivate;

  const _AccountDialog({
    required this.account,
    required this.onDeactivate,
    required this.onReactivate,
  });

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  /// Children with a removal in flight.
  final Set<int> _removing = {};

  List<AdminPlayer> get _children =>
      mockRoster.where((p) => p.parentId == widget.account.id).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Same rules as removing a player from Players: asks first; if they still
  /// owe, asks again before writing it off; training credit has to be
  /// refunded first (the server says so, in words).
  Future<void> _removeChild(AdminPlayer child) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Remove ${child.name}?",
      message:
          "${child.name} will be taken off ${widget.account.name}'s account, "
          "every training and every tournament roster. Their attendance and "
          "payment history is kept.",
      confirmLabel: "REMOVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || !mounted || !_removing.add(child.id)) return;
    setState(() {});
    try {
      await removePlayer(child);
      _showMessage("${child.name} has been removed.");
    } on ApiException catch (e) {
      if (e.statusCode == 409 && e.body['requiresWaiver'] == true && mounted) {
        final waive = await showConfirmDialog(
          context,
          title: "${child.name} still owes AED ${e.body['outstanding']}",
          message:
              "Removing them writes that balance off. Only do this if the "
              "family won't be paying it.",
          confirmLabel: "WAIVE & REMOVE",
          confirmColor: Colors.redAccent,
        );
        if (waive) {
          try {
            await removePlayer(child, waive: true);
            await loadPayments();
            _showMessage("${child.name} has been removed.");
          } catch (e) {
            _showMessage(friendlyError(e));
          }
        }
      } else {
        _showMessage(e.message);
      }
    } catch (e) {
      _showMessage(friendlyError(e));
    } finally {
      _removing.remove(child.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final children = _children;
    final contact = [
      account.email,
      if (account.phone != null && account.phone!.trim().isNotEmpty)
        account.phone!,
    ];
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProfilePhoto(url: account.photoUrl, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "@${account.username}",
                        style: const TextStyle(color: _accent, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (account.disabled)
                  const _Chip("DEACTIVATED", Colors.redAccent),
              ],
            ),
            const SizedBox(height: 10),
            for (final line in contact)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  line,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              "CHILDREN (${children.length})",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            if (children.isEmpty)
              Text(
                "No children on this account.",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            for (final child in children)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            child.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (child.kitLabel != null)
                            Text(
                              child.kitLabel!,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                    _removing.contains(child.id)
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: _accent,
                                strokeWidth: 2,
                              ),
                            ),
                          )
                        : IconButton(
                            onPressed: () => _removeChild(child),
                            tooltip: "Remove ${child.name}",
                            icon: const Icon(
                              Icons.person_remove_outlined,
                              color: Colors.redAccent,
                              size: 20,
                            ),
                          ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            // A message to this family only. Not for a deactivated account:
            // they can't sign in to read it.
            if (!account.disabled) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => showDialog(
                    context: context,
                    barrierColor: Colors.black54,
                    builder: (_) => _SendMessageDialog(accounts: [account]),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(
                    Icons.mail_outline,
                    color: Colors.white,
                    size: 18,
                  ),
                  label: const Text(
                    "SEND MESSAGE",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: account.disabled
                  ? ElevatedButton(
                      onPressed: () async {
                        if (await widget.onReactivate() && context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        "REACTIVATE ACCOUNT",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : OutlinedButton(
                      onPressed: () async {
                        if (await widget.onDeactivate() && context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        "DEACTIVATE ACCOUNT",
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            // For good, unlike deactivate. Its own window makes the admin
            // type the username first.
            SizedBox(
              width: double.infinity,
              // A solid red box: stronger than Deactivate's outline, because
              // this one can't be undone.
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () async {
                  final deleted = await showDialog<bool>(
                    context: context,
                    barrierColor: Colors.black54,
                    builder: (_) => _DeleteAccountDialog(account: account),
                  );
                  if (deleted == true && context.mounted) {
                    Navigator.pop(context);
                  }
                },
                icon: const Icon(
                  Icons.delete_forever_outlined,
                  color: Colors.white,
                  size: 18,
                ),
                label: const Text(
                  "DELETE ACCOUNT",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  "CLOSE",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Deletes a parent account for good. The "are you sure" for something
/// that can't be undone: it says exactly what happens, and DELETE stays
/// off until the admin types the account's username. Refusals (money still
/// owed, credit held) are shown here, in the server's words.
class _DeleteAccountDialog extends StatefulWidget {
  final ParentAccount account;

  const _DeleteAccountDialog({required this.account});

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _confirm = TextEditingController();
  bool _deleting = false;
  String? _error;

  bool get _matches =>
      _confirm.text.trim().toLowerCase() ==
      widget.account.username.toLowerCase();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!_matches || _deleting) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await ApiClient.post('/admin/users/${widget.account.id}/delete', {
        'confirm': _confirm.text.trim(),
      });
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(
        SnackBar(
          content: Text("${widget.account.name}'s account has been deleted."),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final kids = account.children;
    final muted = TextStyle(
      color: Colors.white.withValues(alpha: 0.7),
      fontSize: 13,
      height: 1.4,
    );
    final childLine = kids == 0
        ? ""
        : "•  ${kids == 1 ? 'Their child is' : 'Their $kids children are'} "
              "removed from the academy and from every upcoming training and "
              "tournament.\n";
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.redAccent,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Delete ${account.name}'s account?",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              "This can't be undone. Unlike deactivating, the account is "
              "gone for good:",
              style: muted,
            ),
            const SizedBox(height: 6),
            Text(
              "•  @${account.username} can never log in again, and is signed "
              "out on every device now.\n"
              "•  Their name, email and phone are erased.\n"
              "$childLine"
              "•  Bills and payments already recorded are kept for the "
              "academy's records.",
              style: muted,
            ),
            const SizedBox(height: 6),
            Text(
              "It isn't possible while the family still owes money or the "
              "academy holds training credit for them.",
              style: muted.copyWith(fontSize: 12),
            ),
            const SizedBox(height: 14),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: "Type "),
                  TextSpan(
                    text: account.username,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const TextSpan(text: " to confirm."),
                ],
              ),
              style: muted,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirm,
              enabled: !_deleting,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _delete(),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: Colors.redAccent,
              decoration: InputDecoration(
                hintText: account.username,
                hintStyle: const TextStyle(color: Colors.white24),
                isDense: true,
                filled: true,
                fillColor: _bg,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(
                    color: Colors.redAccent,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _deleting
                        ? null
                        : () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      "CANCEL",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _matches && !_deleting ? _delete : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      disabledBackgroundColor: Colors.redAccent.withValues(
                        alpha: 0.25,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      _deleting ? "DELETING..." : "DELETE",
                      style: TextStyle(
                        color: _matches ? Colors.white : Colors.white38,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Writes a message to one family's account, or to several picked on the
/// list. It appears in each of those parents' Messages (and nobody else's),
/// the same way club messages do. Pops true once sent.
class _SendMessageDialog extends StatefulWidget {
  final List<ParentAccount> accounts;

  const _SendMessageDialog({required this.accounts});

  @override
  State<_SendMessageDialog> createState() => _SendMessageDialogState();
}

class _SendMessageDialogState extends State<_SendMessageDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _error = "Write a title and a message.");
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final accounts = widget.accounts;
      if (accounts.length == 1) {
        await sendDirectMessage(
          userId: accounts.single.id,
          title: title,
          body: body,
        );
      } else {
        await sendMessageToFamilies(
          userIds: [for (final a in accounts) a.id],
          title: title,
          body: body,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            accounts.length == 1
                ? "Message sent to ${accounts.single.name}."
                : "Message sent to ${accounts.length} families.",
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = friendlyError(e);
      });
    }
  }

  /// Who it goes to: one name, a few, or a count with the first few names.
  String get _recipientsLine {
    final names = [for (final a in widget.accounts) a.name];
    if (names.length == 1) {
      return "To ${names.single} only. It appears in their Messages.";
    }
    final shown = names.length <= 4
        ? names.join(", ")
        : "${names.take(3).join(", ")} and ${names.length - 3} more";
    return "To ${names.length} families: $shown. Each sees it in their own "
        "Messages, and not who else it went to.";
  }

  InputDecoration _decoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white30),
    counterStyle: const TextStyle(color: Colors.white38),
    isDense: true,
    filled: true,
    fillColor: _bg,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _accent, width: 1.5),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Send a message",
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _recipientsLine,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _title,
              inputFormatters: [noEmoji],
              maxLength: 160,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: _accent,
              decoration: _decoration("Title"),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _body,
              inputFormatters: [noEmoji],
              maxLines: 6,
              minLines: 4,
              maxLength: 5000,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: _accent,
              decoration: _decoration("Message"),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _sending ? null : () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      "CANCEL",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _sending ? null : _send,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      _sending ? "SENDING..." : "SEND",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the Parent Accounts list can be narrowed to.
const _filterOptions = [
  "All",
  "Active",
  "Deactivated",
  "With children",
  "No children",
  "Password not changed yet",
];

/// How the Parent Accounts list can be ordered.
const _sortOptions = [
  "Name A–Z",
  "Name Z–A",
  "Newest first",
  "Oldest first",
  "Most children",
];
