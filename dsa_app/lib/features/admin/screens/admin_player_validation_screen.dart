import 'package:flutter/material.dart';

import '../../../core/utils/jersey_number.dart';

import '../../../core/services/live_refresh.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/widgets/jersey_number_picker.dart';
import '../../../core/widgets/pressable.dart';
import '../../../core/widgets/profile_photo.dart';
import '../models/mock_roster.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Families asking for a jersey number another player already wears — a
/// new child (not a player until approved) or an existing one changing
/// number. Like Account Validation: approve or decline each one.
class AdminPlayerValidation extends StatefulWidget {
  const AdminPlayerValidation({super.key});

  @override
  State<AdminPlayerValidation> createState() => _AdminPlayerValidationState();
}

class _AdminPlayerValidationState extends State<AdminPlayerValidation>
    with LiveRefreshing<AdminPlayerValidation> {
  @override
  Future<void> reloadQuietly() => loadJerseyRequests();

  bool _loading = true;
  String? _loadError;

  /// Requests with an answer on its way, so a second tap can't send it
  /// twice.
  final Set<int> _working = {};

  @override
  void initState() {
    super.initState();
    // Opened fresh: every request starts on the number the family asked
    // for. (While open, a number chosen with CHANGE NUMBER survives the
    // screen's own reloads until APPROVE.)
    jerseyRequests.clear();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await loadJerseyRequests();
    } catch (e) {
      _loadError = "${friendlyError(e)}\nPull down to try again.";
    }
    if (mounted) setState(() => _loading = false);
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The admin gives a different number than the one asked for. A free one
  /// is simply chosen; a taken one asks first, listing who wears it (the
  /// picker does that). It's only used once APPROVE is tapped.
  Future<void> _changeNumber(JerseyRequest request) async {
    final pick = await pickJerseyNumber(
      context,
      current: request.finalChosen
          ? request.finalNumber
          : jerseyKey(request.requested),
      // Their own current number (an existing player) isn't "taken".
      exceptPlayerId: request.playerId,
      forAdmin: true,
    );
    if (pick == null || !mounted) return;
    setState(() {
      request.finalChosen = '${pick.number}' != request.requested;
      request.finalNumber = pick.number;
      request.finalWornBy = pick.wornBy;
    });
  }

  Future<void> _approve(JerseyRequest request) async {
    final number = request.finalLabel;
    final wornBy = request.finalChosen
        ? (request.finalWornBy.isEmpty ? null : request.finalWornBy.join(', '))
        : request.wornBy;
    final shared = wornBy == null
        ? ""
        : " $wornBy already wears it, so both will have $number.";
    final noNumber = request.finalChosen && request.finalNumber == null;
    final confirmed = await showConfirmDialog(
      context,
      title: noNumber ? "Approve with no number?" : "Approve jersey $number?",
      message: request.isNewPlayer
          ? "${request.playerName} will be added as a player with "
                "$number.$shared"
          : "${request.playerName} will change to $number.$shared",
      confirmLabel: "YES, APPROVE",
    );
    if (!confirmed || !mounted || !_working.add(request.playerId)) return;
    try {
      await approveJerseyRequest(request);
      await loadPlayers();
      _show(
        noNumber
            ? "${request.playerName} is approved, with no number."
            : "${request.playerName} now has jersey $number.",
      );
    } catch (e) {
      _show(friendlyError(e));
    } finally {
      _working.remove(request.playerId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _decline(JerseyRequest request) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Decline jersey #${request.requested}?",
      message: request.isNewPlayer
          ? "${request.parentName} will be asked to choose another number "
                "for ${request.playerName}. ${request.playerName} isn't "
                "added until then."
          : "${request.playerName} keeps "
                "${request.current == null ? 'no number' : '#${request.current}'}"
                ", and ${request.parentName} will be asked to choose another "
                "one.",
      confirmLabel: "DECLINE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || !mounted || !_working.add(request.playerId)) return;
    try {
      await declineJerseyRequest(request);
    } catch (e) {
      _show(friendlyError(e));
    } finally {
      _working.remove(request.playerId);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final requests = jerseyRequests;
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
                  const Expanded(
                    child: Text(
                      "PLAYER VALIDATION",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
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
                    : _loadError != null || requests.isEmpty
                    ? ListView(
                        // Scrollable so pull-to-refresh still works.
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.6,
                            child: Center(
                              child: Text(
                                _loadError ??
                                    "No jersey numbers waiting for approval.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _loadError != null
                                      ? Colors.amber
                                      : Colors.white.withValues(alpha: 0.4),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: requests.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final request = requests[index];
                          return FadeSlideIn(
                            index: index,
                            child: _RequestRow(
                              request: request,
                              onApprove: () => _approve(request),
                              onDecline: () => _decline(request),
                              onChangeNumber: () => _changeNumber(request),
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

class _RequestRow extends StatelessWidget {
  final JerseyRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDecline;
  final VoidCallback onChangeNumber;

  const _RequestRow({
    required this.request,
    required this.onApprove,
    required this.onDecline,
    required this.onChangeNumber,
  });

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Colors.white.withValues(alpha: 0.55),
      fontSize: 12,
    );
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProfilePhoto(url: request.photoUrl, radius: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.playerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (request.birthYear != null) "B${request.birthYear}",
                        request.isNewPlayer
                            ? "New player"
                            : "Now "
                                  "${request.current == null ? 'no number' : '#${request.current}'}",
                      ].join(" · "),
                      style: muted,
                    ),
                    const SizedBox(height: 4),
                    if (!request.finalChosen) ...[
                      Text(
                        "Wants jersey #${request.requested}",
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (request.wornBy != null)
                        _WornBy(
                          label: "Already worn by",
                          wearers: _splitWearers(request.wornBy!),
                        ),
                    ] else ...[
                      Text("Asked for #${request.requested}", style: muted),
                      Text(
                        request.finalNumber == null
                            ? "Final: no number"
                            : "Final: jersey #${jerseyText(request.finalNumber!)}",
                        style: const TextStyle(
                          color: _accent,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (request.finalWornBy.isNotEmpty)
                        _WornBy(
                          label: "Also worn by",
                          wearers: request.finalWornBy,
                        ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      [
                        request.parentName,
                        if (request.parentPhone.isNotEmpty) request.parentPhone,
                      ].join(" · "),
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
                  _ActionButton(
                    label: "APPROVE",
                    color: _accent,
                    onTap: onApprove,
                  ),
                  const SizedBox(height: 6),
                  _ActionButton(
                    label: "DECLINE",
                    color: Colors.redAccent,
                    onTap: onDecline,
                  ),
                ],
              ),
            ],
          ),
          // Bottom right: the admin can give a different number before
          // approving.
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onChangeNumber,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.fromLTRB(8, 8, 2, 0),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.edit, size: 13, color: _accent),
              label: const Text(
                "CHANGE NUMBER",
                style: TextStyle(
                  color: _accent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Mia Cruz (B2018), Noah Tan (B2013)" from the server, as one
/// entry per player. Player names are letters only, so the "(B2018)" after
/// each one is what marks where it ends.
List<String> _splitWearers(String wornBy) => [
  for (final m in RegExp(r'\s*,?\s*([^,]+?\(B\d{4}\))').allMatches(wornBy))
    m.group(1)!,
];

/// Who already wears a number: a small label, then one line per player,
/// always "Name · B2018", so a long list stays easy to read.
class _WornBy extends StatelessWidget {
  final String label;

  /// Each "Name (B2018)".
  final List<String> wearers;

  const _WornBy({required this.label, required this.wearers});

  @override
  Widget build(BuildContext context) {
    final muted = Colors.white.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: muted, fontSize: 11)),
          const SizedBox(height: 2),
          for (final wearer in wearers)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _WearerLine(wearer: wearer),
            ),
        ],
      ),
    );
  }
}

class _WearerLine extends StatelessWidget {
  final String wearer;

  const _WearerLine({required this.wearer});

  @override
  Widget build(BuildContext context) {
    final match = RegExp(r'^(.*?)\s*\((B\d{4})\)$').firstMatch(wearer.trim());
    final name = match?.group(1) ?? wearer;
    final category = match?.group(2);
    return Row(
      children: [
        Container(
          width: 4,
          height: 4,
          margin: const EdgeInsets.only(right: 8),
          decoration: const BoxDecoration(
            color: Colors.white38,
            shape: BoxShape.circle,
          ),
        ),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        if (category != null)
          Text(
            "  ·  $category",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
            ),
          ),
      ],
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
