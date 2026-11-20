import 'dart:convert';

import '../../core/utils/friendly_error.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';

/// Profile photos for accounts and players: the "Take Photo" / "Choose from
/// Gallery" menu, picking and shrinking the picture, uploading it, and the
/// round avatar that shows it.
///
/// The server keeps the picture and decides who may see it (an account's
/// photo: that account and admins; a child's: their parent and admins). A
/// photo's address ('/photos/player/12?v=...') changes whenever a new one
/// is saved, so a phone never shows the old one.

/// What the person picked in the photo menu.
enum PhotoChoice { camera, gallery, remove }

/// Pictures already loaded this run, by address, so scrolling a list or
/// reopening a screen doesn't download them again.
final Map<String, Uint8List> _loaded = {};

/// The menu: Take Photo, Choose from Gallery, and Remove photo when there
/// is one. Null if dismissed.
Future<PhotoChoice?> showPhotoMenu(
  BuildContext context, {
  required bool hasPhoto,
}) {
  Widget option(
    IconData icon,
    String label,
    PhotoChoice choice, {
    Color color = Colors.white,
  }) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () => Navigator.pop(context, choice),
    );
  }

  return showModalBottomSheet<PhotoChoice>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          option(Icons.camera_alt, "Take Photo", PhotoChoice.camera),
          option(
            Icons.photo_library,
            "Choose from Gallery",
            PhotoChoice.gallery,
          ),
          if (hasPhoto)
            option(
              Icons.delete_outline,
              "Remove photo",
              PhotoChoice.remove,
              color: Colors.redAccent,
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Opens the camera or the gallery. The picture comes back shrunk to about
/// 600 px and compressed (tens of KB), so it uploads quickly and the server
/// accepts it. Null if cancelled.
Future<Uint8List?> pickPhoto(PhotoChoice source) async {
  final file = await ImagePicker().pickImage(
    source: source == PhotoChoice.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxWidth: 600,
    maxHeight: 600,
    imageQuality: 80,
    preferredCameraDevice: CameraDevice.front,
  );
  return file?.readAsBytes();
}

/// Saves the photo for an account ([kind] 'user') or a child ('player').
/// Returns its new address.
Future<String> uploadPhoto(String kind, int id, Uint8List bytes) async {
  final result = await ApiClient.put('/photos/$kind/$id', {
    'image': base64Encode(bytes),
  });
  final url = result['photoUrl'] as String;
  _loaded[url] = bytes;
  return url;
}

Future<void> removePhoto(String kind, int id) =>
    ApiClient.delete('/photos/$kind/$id');

/// The whole flow behind a photo button: menu, then camera / gallery and
/// upload, or remove. Returns the new address ('' when removed), or null
/// if nothing changed. Problems are shown as a message.
Future<String?> changePhoto(
  BuildContext context, {
  required String kind,
  required int id,
  required bool hasPhoto,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showPhotoMenu(context, hasPhoto: hasPhoto);
  if (choice == null) return null;
  try {
    if (choice == PhotoChoice.remove) {
      await removePhoto(kind, id);
      messenger.showSnackBar(const SnackBar(content: Text("Photo removed")));
      return '';
    }
    final bytes = await pickPhoto(choice);
    if (bytes == null) return null;
    final url = await uploadPhoto(kind, id, bytes);
    messenger.showSnackBar(const SnackBar(content: Text("Photo saved")));
    return url;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          e.toString().contains('camera_access_denied') ||
                  e.toString().contains('photo_access_denied')
              ? "Please allow access to your camera or photos in your phone's "
                    "settings to add a photo."
              : friendlyError(e),
        ),
      ),
    );
    return null;
  }
}

/// A round photo: the picture at [url] (or the [preview] bytes just picked),
/// otherwise the usual person icon. Loading or a missing picture shows the
/// icon too, so it never looks broken.
class ProfilePhoto extends StatefulWidget {
  final String? url;
  final Uint8List? preview;
  final double radius;

  const ProfilePhoto({super.key, this.url, this.preview, this.radius = 40});

  @override
  State<ProfilePhoto> createState() => _ProfilePhotoState();
}

class _ProfilePhotoState extends State<ProfilePhoto> {
  Uint8List? _bytes;

  /// The address being downloaded, so a rebuild doesn't start a second one.
  String? _downloading;

  /// When the last try failed. A photo that didn't load (no signal for a
  /// moment, the server busy) used to stay an icon until the app was
  /// restarted; now the next rebuild tries again — the lists refresh every
  /// 20 seconds — but not more often than every [_retryAfter].
  DateTime? _failedAt;
  static const _retryAfter = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _bytes = _cached(widget.url);
    _load();
  }

  @override
  void didUpdateWidget(ProfilePhoto old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      // A new photo (or none): show it from memory if it's there, and
      // never keep showing the old one.
      _bytes = _cached(widget.url);
      _failedAt = null;
    }
    _load();
  }

  static Uint8List? _cached(String? url) => url == null ? null : _loaded[url];

  Future<void> _load() async {
    final url = widget.url;
    if (url == null || url.isEmpty || _bytes != null) return;
    if (_downloading == url) return;
    final failedAt = _failedAt;
    if (failedAt != null && DateTime.now().difference(failedAt) < _retryAfter) {
      return;
    }
    _downloading = url;
    try {
      final bytes = await ApiClient.getBytes(url);
      if (bytes != null) _loaded[url] = bytes;
      if (mounted && widget.url == url) {
        setState(() {
          _bytes = bytes;
          _failedAt = bytes == null ? DateTime.now() : null;
        });
      }
    } catch (_) {
      // No signal or not allowed: the icon stays until the next try.
      _failedAt = DateTime.now();
    } finally {
      if (_downloading == url) _downloading = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.preview ?? _bytes;
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: Colors.white12,
      foregroundImage: image == null ? null : MemoryImage(image),
      child: Icon(
        Icons.person,
        color: Colors.white54,
        size: widget.radius * 1.05,
      ),
    );
  }
}

/// A closer look at a photo: tapping someone's round photo opens it large,
/// pinch to zoom in further. Tap outside (or the X) to close. Does nothing
/// when there's no photo.
Future<void> showPhotoViewer(
  BuildContext context, {
  required String? url,
  required String title,
}) async {
  if (url == null || url.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => _PhotoViewer(url: url, title: title),
  );
}

class _PhotoViewer extends StatefulWidget {
  final String url;
  final String title;

  const _PhotoViewer({required this.url, required this.title});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _bytes = _loaded[widget.url];
    if (_bytes == null) _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await ApiClient.getBytes(widget.url);
      if (bytes != null) _loaded[widget.url] = bytes;
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _failed = bytes == null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final side = MediaQuery.sizeOf(context).width - 48;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: "Close",
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: side,
              height: side,
              child: bytes != null
                  ? InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Image.memory(bytes, fit: BoxFit.cover),
                    )
                  : ColoredBox(
                      color: Colors.white10,
                      child: Center(
                        child: _failed
                            ? const Text(
                                "The photo couldn't be loaded.",
                                style: TextStyle(color: Colors.white54),
                              )
                            : const CircularProgressIndicator(
                                color: Colors.green,
                              ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "Pinch to zoom",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
