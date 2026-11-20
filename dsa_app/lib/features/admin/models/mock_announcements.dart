import '../../../core/services/api_client.dart';

const everyoneAudience = "Everyone";

/// One training or tournament an announcement was addressed to.
typedef AudienceRef = ({String id, String name});

/// An announcement sent from admin to parents. Either club-wide
/// ([isEveryone]) or scoped to any mix of categories, trainings and
/// tournaments.
///
/// Backed by `announcements` plus its three audience link tables.
class SentAnnouncement {
  final String id;
  final String title;
  final String body;

  /// Category codes, or just [everyoneAudience] for a club-wide message.
  final List<String> audiences;
  final List<AudienceRef> trainings;
  final List<AudienceRef> tournaments;

  /// Every player currently in one of [trainings] or [tournaments],
  /// resolved by the server. Parents match on this, by id — never by name.
  final Set<int> memberPlayerIds;

  /// Players it was sent to by name — the automatic cancellation notices,
  /// which go to exactly the players on what was cancelled.
  final List<AudienceRef> players;

  /// 'sessions_cancelled', 'tournament_cancelled', 'session_changed' or
  /// 'sessions_added' for a notice the server sent by itself; null for one
  /// an admin wrote.
  final String? autoKind;

  /// Set on a message sent to one family's account (Parent Accounts > Send
  /// message): who it went to. A parent only ever receives their own.
  final List<AudienceRef> recipients;
  final String time;

  /// Whether this parent has opened it. Always true on the admin side.
  bool isRead;

  SentAnnouncement({
    this.id = '',
    required this.title,
    required this.body,
    required this.audiences,
    this.trainings = const [],
    this.tournaments = const [],
    this.memberPlayerIds = const {},
    this.players = const [],
    this.autoKind,
    this.recipients = const [],
    required this.time,
    this.isRead = true,
  });

  bool get isEveryone => audiences.contains(everyoneAudience);

  List<String> get categoryCodes =>
      audiences.where((a) => a != everyoneAudience).toList();

  String get audienceLabel {
    if (isEveryone) return everyoneAudience;
    // A family telling the academy they declined a tournament (and why):
    // it went to no family.
    if (autoKind == 'tournament_declined') return "The academy (from a family)";
    final parts = [
      ...categoryCodes,
      ...trainings.map((t) => t.name),
      ...tournaments.map((t) => t.name),
      // A message to several families at once names them while it's short.
      if (recipients.length <= 2)
        ...recipients.map((r) => r.name)
      else
        "${recipients.length} families",
      // A tournament notice already names the tournament; the players on
      // it are only worth listing for a sessions notice.
      if (players.isNotEmpty && tournaments.isEmpty)
        players.length <= 2
            ? players.map((p) => p.name).join(", ")
            : "${players.length} players",
    ];
    // Only reachable if every tournament it named has since been deleted.
    return parts.isEmpty ? "No audience" : parts.join(", ");
  }

  /// Whether a parent whose players are in [categories] and have
  /// [playerIds] should see this. The one rule both parent screens use.
  bool isVisibleTo({
    required Set<String> categories,
    required Set<int> playerIds,
  }) =>
      isEveryone ||
      categoryCodes.any(categories.contains) ||
      memberPlayerIds.any(playerIds.contains) ||
      // Sent to this parent's own account: the server only includes a
      // recipient for the family it was sent to.
      recipients.isNotEmpty;
}

final List<SentAnnouncement> mockAnnouncements = [];

/// "2026-09-10 13:23:28" -> "Sep 10" (or "13:23" when it's today), which
/// is all the list rows show.
String _formatSentAt(String? raw) {
  if (raw == null) return '';
  final sent = DateTime.tryParse(raw);
  if (sent == null) return raw;
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  final now = DateTime.now();
  final isToday =
      sent.year == now.year && sent.month == now.month && sent.day == now.day;
  if (isToday) {
    final hour = sent.hour % 12 == 0 ? 12 : sent.hour % 12;
    final suffix = sent.hour >= 12 ? 'PM' : 'AM';
    return '$hour:${sent.minute.toString().padLeft(2, '0')} $suffix';
  }
  // The year too once it isn't this year: "Sep 10" from last year read as
  // this week's news.
  if (sent.year != now.year) {
    return '${months[sent.month - 1]} ${sent.day}, ${sent.year}';
  }
  return '${months[sent.month - 1]} ${sent.day}';
}

List<AudienceRef> _refs(Object? raw) => [
  for (final item in (raw as List? ?? []).cast<Map<String, dynamic>>())
    (id: '${item['id']}', name: '${item['name']}'),
];

Future<void> loadAnnouncements() async {
  final rows = await ApiClient.getList('/announcements');
  mockAnnouncements
    ..clear()
    ..addAll(
      // "Order received" messages were sent for a day (19 Oct 2026) and then
      // dropped: an order simply shows RECEIVED under My Orders. Any left
      // over aren't shown.
      rows.where((row) => (row as Map)['auto_kind'] != 'order_given').map((
        row,
      ) {
        final map = row as Map<String, dynamic>;
        final isEveryone = '${map['is_everyone']}' == '1';
        return SentAnnouncement(
          id: '${map['id']}',
          title: map['title'] as String,
          body: map['body'] as String,
          audiences: isEveryone
              ? [everyoneAudience]
              : asCsvList(map['audiences']),
          trainings: isEveryone ? const [] : _refs(map['trainings']),
          tournaments: isEveryone ? const [] : _refs(map['tournaments']),
          memberPlayerIds: {
            for (final id in (map['member_player_ids'] as List? ?? []))
              asInt(id),
          },
          players: _refs(map['players']),
          recipients: _refs(map['recipients']),
          autoKind: map['auto_kind'] as String?,
          time: _formatSentAt(map['created_at'] as String?),
          // Only sent to parents; an admin's copy counts as read.
          isRead: map['is_read'] != false,
        );
      }),
    );
}

/// Sends a message to one parent account only (Parent Accounts > Send
/// message). It shows in that family's Messages and nobody else's.
Future<void> sendDirectMessage({
  required int userId,
  required String title,
  required String body,
}) async {
  await ApiClient.post('/admin/users/$userId/message', {
    'title': title,
    'body': body,
  });
  try {
    await loadAnnouncements();
  } catch (_) {
    // Sent; the admin's own message list just catches up later.
  }
}

/// Sends ONE message to several parent accounts at once (Parent Accounts >
/// the message icon > tick families > ADD MESSAGE). Each family sees it in
/// their own Messages; the admin's list shows it once.
Future<void> sendMessageToFamilies({
  required List<int> userIds,
  required String title,
  required String body,
}) async {
  await ApiClient.post('/admin/messages', {
    'userIds': userIds,
    'title': title,
    'body': body,
  });
  try {
    await loadAnnouncements();
  } catch (_) {
    // Sent; the admin's own message list just catches up later.
  }
}

Map<String, dynamic> _payload({
  required String title,
  required String body,
  required List<String> audiences,
  required List<String> trainingIds,
  required List<String> tournamentIds,
}) {
  final isEveryone = audiences.contains(everyoneAudience);
  return {
    'title': title,
    'body': body,
    'isEveryone': isEveryone,
    'audiences': isEveryone ? [] : audiences,
    'trainingIds': isEveryone ? [] : trainingIds,
    'tournamentIds': isEveryone ? [] : tournamentIds,
  };
}

Future<void> addAnnouncement({
  required String title,
  required String body,
  required List<String> audiences,
  List<String> trainingIds = const [],
  List<String> tournamentIds = const [],
}) async {
  await ApiClient.post(
    '/announcements',
    _payload(
      title: title,
      body: body,
      audiences: audiences,
      trainingIds: trainingIds,
      tournamentIds: tournamentIds,
    ),
  );
  await loadAnnouncements();
}

Future<void> updateAnnouncement(
  SentAnnouncement announcement, {
  required String title,
  required String body,
  required List<String> audiences,
  List<String> trainingIds = const [],
  List<String> tournamentIds = const [],
}) async {
  await ApiClient.put(
    '/announcements/${announcement.id}',
    _payload(
      title: title,
      body: body,
      audiences: audiences,
      trainingIds: trainingIds,
      tournamentIds: tournamentIds,
    ),
  );
  await loadAnnouncements();
}

/// Marks a message as read for this parent, so it stops showing as new.
/// Best effort: if the request fails it simply shows as new again next time.
Future<void> markAnnouncementRead(SentAnnouncement announcement) async {
  if (announcement.isRead || announcement.id.isEmpty) return;
  announcement.isRead = true;
  try {
    await ApiClient.post('/announcements/${announcement.id}/read');
  } catch (_) {}
}

/// Soft-deleted server-side (deleted_at), so it stays auditable.
Future<void> removeAnnouncement(SentAnnouncement announcement) async {
  await ApiClient.delete('/announcements/${announcement.id}');
  mockAnnouncements.remove(announcement);
}
