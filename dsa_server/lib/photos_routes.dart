import 'dart:convert';
import 'dart:typed_data';

import 'package:mysql_client/mysql_client.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'db.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// The largest photo accepted. The phone shrinks pictures to about 600 px
/// before sending (tens of KB), so this only stops a mistake or abuse.
const _maxPhotoBytes = 1024 * 1024;

/// Profile photos: "Take Photo" / "Choose from Gallery" on the Account
/// screens and on a player.
///
///   GET    /photos/<kind>/<id>   the picture (image/jpeg or image/png)
///   PUT    /photos/<kind>/<id>   {"image": "<base64 JPEG or PNG>"}
///   DELETE /photos/<kind>/<id>   remove it
///
/// <kind> is `user` (an account) or `player`. Who may see or change one:
/// an account's photo — that account and admins; a child's photo — their
/// own parent and admins. Anyone else gets "not found", so ids can't be
/// probed. The picture is stored in profile_photos; users.photo_url /
/// players.photo_url hold the address to load it from, with a version so a
/// new photo replaces the old one on every phone.
Router buildPhotosRouter(Db db) {
  final router = Router();

  /// Whether [user] may see / change this photo, and that its owner exists.
  Future<bool> allowed(AuthUser user, String kind, int id) async {
    if (kind == 'user') {
      if (!user.isAdmin && user.id != id) return false;
      final found = await db.execute(
        'SELECT id FROM users WHERE id = :id AND deleted_at IS NULL',
        {'id': id},
      );
      return found.rows.isNotEmpty;
    }
    if (kind == 'player')
      return canAccessPlayer(db, user, id, includeUnapproved: true);
    return false;
  }

  Response notFound() => _json({'error': 'No photo here'}, status: 404);

  router.get('/photos/<kind>/<id>', (
    Request request,
    String kind,
    String id,
  ) async {
    final ownerId = int.tryParse(id);
    if (ownerId == null || !await allowed(userOf(request), kind, ownerId)) {
      return notFound();
    }
    // As base64 text: the MySQL driver hands every column back as a
    // string, which would mangle raw image bytes.
    final found = await db.execute(
      "SELECT REPLACE(TO_BASE64(image), '\n', '') AS image, mime "
      'FROM profile_photos WHERE kind = :kind AND owner_id = :id',
      {'kind': kind, 'id': ownerId},
    );
    if (found.rows.isEmpty) return notFound();
    final row = found.rows.first.assoc();
    return Response.ok(
      base64Decode(row['image']!),
      headers: {
        'Content-Type': row['mime'] ?? 'image/jpeg',
        // The address carries a version, so a phone may keep it.
        'Cache-Control': 'private, max-age=86400',
      },
    );
  });

  router.put('/photos/<kind>/<id>', (
    Request request,
    String kind,
    String id,
  ) async {
    final ownerId = int.tryParse(id);
    if (ownerId == null || !await allowed(userOf(request), kind, ownerId)) {
      return notFound();
    }
    final body = jsonDecode(await request.readAsString());
    final encoded = body is Map ? '${body['image'] ?? ''}' : '';
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      return _json({'error': "That photo couldn't be read"}, status: 400);
    }
    if (bytes.isEmpty) {
      return _json({'error': 'No photo was sent'}, status: 400);
    }
    if (bytes.length > _maxPhotoBytes) {
      return _json({
        'error': 'That photo is too large. Please choose a smaller one.',
      }, status: 400);
    }
    final mime = _imageType(bytes);
    if (mime == null) {
      return _json({
        'error': 'Please choose a photo (JPEG or PNG).',
      }, status: 400);
    }
    final url = await db.transaction((conn) async {
      await conn.execute(
        'INSERT INTO profile_photos (kind, owner_id, image, mime) '
        'VALUES (:kind, :id, FROM_BASE64(:image), :mime) '
        'ON DUPLICATE KEY UPDATE image = VALUES(image), '
        'mime = VALUES(mime), updated_at = NOW()',
        {'kind': kind, 'id': ownerId, 'image': encoded, 'mime': mime},
      );
      final url =
          '/photos/$kind/$ownerId?v=${DateTime.now().millisecondsSinceEpoch}';
      await conn.execute(
        'UPDATE ${kind == 'user' ? 'users' : 'players'} '
        'SET photo_url = :url WHERE id = :id',
        {'url': url, 'id': ownerId},
      );
      return url;
    });
    return _json({'photoUrl': url});
  });

  router.delete('/photos/<kind>/<id>', (
    Request request,
    String kind,
    String id,
  ) async {
    final ownerId = int.tryParse(id);
    if (ownerId == null || !await allowed(userOf(request), kind, ownerId)) {
      return notFound();
    }
    await db.transaction(
      (conn) => deletePhoto(conn, kind: kind, ownerId: ownerId),
    );
    return _json({'removed': true});
  });

  return router;
}

/// Removes a photo and clears the address pointing at it. Also used when a
/// player is removed or an account is deleted: a child's picture must not
/// outlive their place in the club. [kind] is 'user' or 'player'.
Future<void> deletePhoto(
  MySQLConnection conn, {
  required String kind,
  required int ownerId,
}) async {
  await conn.execute(
    'DELETE FROM profile_photos WHERE kind = :kind AND owner_id = :id',
    {'kind': kind, 'id': ownerId},
  );
  await conn.execute(
    'UPDATE ${kind == 'user' ? 'users' : 'players'} '
    'SET photo_url = NULL WHERE id = :id',
    {'id': ownerId},
  );
}

/// JPEG or PNG by its first bytes, or null for anything else.
String? _imageType(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length > 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  return null;
}
