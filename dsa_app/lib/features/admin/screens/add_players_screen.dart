import 'package:flutter/material.dart';

import '../../../core/widgets/profile_photo.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/category_age.dart';
import '../models/admin_player.dart';
import '../models/mock_roster.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Full-screen player picker shared by Trainings and Tournaments — a
/// screen rather than a sheet since the roster can grow large. Lets the
/// admin switch between players already in the given category (or
/// categories, for a training spanning more than one) and everyone
/// else, with a search bar and a select-all shortcut.
class AddPlayersScreen extends StatefulWidget {
  final String categoryLabel;
  final List<String> categories;

  /// Player ids already on the roster — ids, not names, since two players
  /// can share a name.
  final List<int> alreadyAdded;
  // Tournaments only: hide "other players" who are overage for this
  // category (born earlier than it) — an older player can't play down
  // into a younger bracket. Trainings show everyone regardless of age,
  // since a training roster isn't bound by tournament eligibility rules.
  final bool restrictOverage;

  /// Choosing a training's DEFAULT players rather than adding to a roster:
  /// these start ticked (untick to take someone off), and the full choice
  /// comes back, even an empty one.
  final List<int>? defaults;

  const AddPlayersScreen({
    super.key,
    required this.categoryLabel,
    required this.categories,
    required this.alreadyAdded,
    this.restrictOverage = false,
    this.defaults,
  });

  @override
  State<AddPlayersScreen> createState() => _AddPlayersScreenState();
}

enum _PlayerScope { inCategory, others }

class _AddPlayersScreenState extends State<AddPlayersScreen> {
  final Set<int> _selected = {};
  _PlayerScope _scope = _PlayerScope.inCategory;
  String _query = "";

  bool get _choosingDefaults => widget.defaults != null;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.defaults ?? const []);
  }

  List<AdminPlayer> get _eligible {
    final wantsInCategory = _scope == _PlayerScope.inCategory;
    // Only meaningful (and only ever applied) when there's exactly one
    // target category — a multi-category training never restricts overage.
    final targetYear = widget.categories.length == 1
        ? categoryBirthYear(widget.categories.first)
        : null;
    return mockRoster.where((p) {
      final inCategory = p.categories.any(widget.categories.contains);
      final matchesScope = wantsInCategory ? inCategory : !inCategory;
      if (!matchesScope) return false;

      // A larger birth year means born later, i.e. younger. Overage means
      // born earlier (a smaller year) than the target category.
      if (!wantsInCategory && widget.restrictOverage && targetYear != null) {
        final years = p.categories
            .map(categoryBirthYear)
            .whereType<int>()
            .toList();
        if (years.isNotEmpty && years.any((year) => year < targetYear)) {
          return false;
        }
      }

      final matchesQuery = p.matchesSearch(_query);
      return matchesQuery &&
          (_choosingDefaults || !widget.alreadyAdded.contains(p.id));
    }).toList();
  }

  void _submit() {
    Navigator.pop(context, _selected.toList());
  }

  bool _allSelected(List<AdminPlayer> eligible) =>
      eligible.isNotEmpty && eligible.every((p) => _selected.contains(p.id));

  void _toggleSelectAll(List<AdminPlayer> eligible) {
    setState(() {
      if (_allSelected(eligible)) {
        for (final p in eligible) {
          _selected.remove(p.id);
        }
      } else {
        for (final p in eligible) {
          _selected.add(p.id);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final eligible = _eligible;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: Text(
          _choosingDefaults
              ? "DEFAULT PLAYERS · ${widget.categoryLabel}"
              : "ADD PLAYERS · ${widget.categoryLabel}",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: "Search players...",
                  hintStyle: const TextStyle(
                    color: Colors.white38,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: Colors.white38,
                    size: 20,
                  ),
                  filled: true,
                  fillColor: _card,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (_choosingDefaults)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  "Ticked players are added to every new session of this "
                  "training automatically. Sessions already scheduled "
                  "aren't changed.",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _ScopeButton(
                      label: widget.categoryLabel.toUpperCase(),
                      selected: _scope == _PlayerScope.inCategory,
                      onTap: () =>
                          setState(() => _scope = _PlayerScope.inCategory),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ScopeButton(
                      label: "OTHER PLAYERS",
                      selected: _scope == _PlayerScope.others,
                      onTap: () => setState(() => _scope = _PlayerScope.others),
                    ),
                  ),
                ],
              ),
            ),
            if (_scope == _PlayerScope.inCategory && eligible.isNotEmpty) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    onTap: () => _toggleSelectAll(eligible),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _allSelected(eligible)
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            color: _accent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _allSelected(eligible)
                                ? "Deselect all"
                                : "Select all",
                            style: const TextStyle(
                              color: _accent,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: eligible.isEmpty
                  ? Center(
                      child: Text(
                        _scope == _PlayerScope.inCategory
                            ? "No more eligible players in ${widget.categoryLabel}."
                            : "No other players found.",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      itemCount: eligible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final player = eligible[index];
                        final isSelected = _selected.contains(player.id);
                        return InkWell(
                          onTap: () => setState(() {
                            if (isSelected) {
                              _selected.remove(player.id);
                            } else {
                              _selected.add(player.id);
                            }
                          }),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? _accent : Colors.white12,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isSelected
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  color: isSelected ? _accent : Colors.white38,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                ProfilePhoto(url: player.photoUrl, radius: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        player.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        player.categories.join(", "),
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.5,
                                          ),
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _selected.isEmpty && !_choosingDefaults
                      ? null
                      : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    disabledBackgroundColor: Colors.white12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _choosingDefaults
                        ? (_selected.isEmpty
                              ? "SAVE: NO DEFAULT PLAYERS"
                              : "SAVE ${_selected.length} DEFAULT PLAYER${_selected.length == 1 ? '' : 'S'}")
                        : _selected.isEmpty
                        ? "SELECT PLAYERS"
                        : "ADD ${_selected.length} PLAYER${_selected.length == 1 ? '' : 'S'}",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
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

class _ScopeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ScopeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? _accent.withValues(alpha: 0.18) : _card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? _accent : Colors.white12),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? _accent : Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
