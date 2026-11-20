import 'dart:io';

/// The phone can't reach the server: no internet, no route, or the secure
/// connection couldn't be set up. Android and desktop builds.
bool isNetworkError(Object error) =>
    error is SocketException || error is HandshakeException;
