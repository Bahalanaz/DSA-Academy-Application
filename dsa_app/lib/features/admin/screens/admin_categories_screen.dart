import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/services/live_refresh.dart';
import '../models/mock_categories.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// The single place new birth-year categories (B2012, B2013, ...) get created.
/// Writes go straight to the shared category list, so every picker
/// across Schedule, Trainings, Tournaments, Players, and Messages picks
/// it up immediately — nothing else needs its own "+" to add one.
class AdminCategoriesScreen extends StatefulWidget {
  const AdminCategoriesScreen({super.key});

  @override
  State<AdminCategoriesScreen> createState() => _AdminCategoriesScreenState();
}

class _AdminCategoriesScreenState extends State<AdminCategoriesScreen>
    with LiveRefreshing<AdminCategoriesScreen> {
  @override
  Future<void> reloadQuietly() async {
    await loadCategories();
  }

  final _newCategoryController = TextEditingController();
  bool _editMode = false;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _newCategoryController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await loadCategories();
    } catch (e) {
      _loadError = "${friendlyError(e)}\nPull down to try again.";
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toggleEditMode() {
    setState(() => _editMode = !_editMode);
  }

  Future<void> _addCategory() async {
    final digits = _newCategoryController.text.trim();
    if (digits.isEmpty) return;
    try {
      await addMockCategory("B$digits");
      _newCategoryController.clear();
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  /// Removal happens the moment the X is tapped, so ask first.
  Future<void> _removeCategory(String category) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Remove $category?",
      message:
          "It disappears from every category picker and from players born "
          "that year. Messages already sent to it are kept. You can add it "
          "back later.",
      confirmLabel: "REMOVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    try {
      await removeMockCategory(category);
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  String _friendlyError(Object e) => friendlyError(e);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: const Text(
          "CATEGORIES",
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Existing categories",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  InkWell(
                    onTap: _toggleEditMode,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: _editMode
                          // Each removal is saved as it happens, so there's
                          // nothing to "apply" — this just leaves edit mode.
                          ? const Text(
                              "DONE",
                              style: TextStyle(
                                color: _accent,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : const Icon(
                              Icons.edit_outlined,
                              color: Colors.white54,
                              size: 17,
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _accent,
                    ),
                  ),
                )
              else if (_loadError != null)
                InkWell(
                  onTap: _refresh,
                  child: Row(
                    children: [
                      const Icon(Icons.refresh, color: Colors.amber, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        _loadError!,
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: mockCategories
                      .map(
                        (c) => Container(
                          padding: EdgeInsets.only(
                            left: 14,
                            right: _editMode ? 6 : 14,
                            top: 6,
                            bottom: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _card,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                c,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                              if (_editMode) ...[
                                const SizedBox(width: 2),
                                InkWell(
                                  onTap: () => _removeCategory(c),
                                  borderRadius: BorderRadius.circular(12),
                                  child: const Padding(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(
                                      Icons.close,
                                      color: Colors.white54,
                                      size: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              const SizedBox(height: 28),
              Text(
                "New category",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _newCategoryController,
                onSubmitted: (_) => _addCategory(),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  prefixText: "B",
                  prefixStyle: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  hintText: "e.g. 2010",
                  hintStyle: const TextStyle(color: Colors.white38),
                  isDense: true,
                  filled: true,
                  fillColor: _card,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _accent, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _addCategory,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    "ADD CATEGORY",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
