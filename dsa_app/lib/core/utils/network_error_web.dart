/// The web version: the browser reports a lost connection as the http
/// package's ClientException, which friendlyError handles already, and
/// dart:io doesn't exist there.
bool isNetworkError(Object error) => false;
