import '../../../core/services/session.dart';
import '../../admin/models/admin_player.dart';
import '../../admin/models/mock_roster.dart';

/// The signed-in parent, read from the live session rather than hardcoded
/// — whoever actually logged in is who the parent side shows.
///
/// The empty-string fallbacks only apply when there's no session at all
/// (e.g. a hot reload that skipped the login screen); in that state the
/// parent screens simply show nothing rather than someone else's data.
String get currentParentName => Session.current?.fullName ?? '';
String get currentParentEmail => Session.current?.email ?? '';

/// Taken from the first matching player row, since users.phone isn't part
/// of the login response.
String get currentParentPhone =>
    myPlayers.isEmpty ? '' : myPlayers.first.parentPhone;

/// This parent's players, resolved out of the shared roster by guardian —
/// the same link `players.parent_id` models in the database. Matched on
/// the user id, so two parents sharing a name can't see each other's
/// children.
///
/// Only approved players: a child still waiting on Player Validation isn't
/// a player yet, so they're left out of orders, payments, the schedule and
/// messages. [myAllPlayers] includes them, for My Players.
List<AdminPlayer> get myPlayers =>
    myAllPlayers.where((p) => p.isApproved).toList();

/// Every child on this account, including any waiting on Player Validation.
List<AdminPlayer> get myAllPlayers {
  final userId = Session.current?.id;
  if (userId == null) return [];
  return mockRoster.where((p) => p.parentId == userId).toList();
}

List<String> get myPlayerNames => myPlayers.map((p) => p.name).toList();

/// Use this, not [myPlayerNames], to decide whether a payment or order
/// belongs to this parent. Two players can share a name, and matching on
/// one would show this parent another family's charges.
Set<int> get myPlayerIds => myPlayers.map((p) => p.id).toSet();

/// Every child's id, including any waiting on Player Validation: messages
/// about a waiting child (their jersey number was approved or declined)
/// are addressed to them, and must show up too.
Set<int> get myAllPlayerIds => myAllPlayers.map((p) => p.id).toSet();
