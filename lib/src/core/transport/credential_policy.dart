/// Decides whether credentials may be sent to a URL.
abstract final class CredentialPolicy {
  /// Whether [uri] is encrypted (`https`/`wss`) or points at this machine or
  /// a private network (`localhost`, `127.x`, `10.x`, `192.168.x`,
  /// `172.16-31.x`, `*.local`), which covers emulators and LAN development.
  static bool isSafeForCredentials(Uri uri) {
    if (uri.scheme == 'https' || uri.scheme == 'wss') return true;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '::1' || host.endsWith('.local')) {
      return true;
    }
    final octets = host.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.contains(null)) return false;
    final [a, b, _, _] = octets.cast<int>();
    return a == 127 ||
        a == 10 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31);
  }

  /// The message used when credentials are withheld from [uri].
  static String insecureMessage(Uri uri) =>
      'Refusing to send credentials over unencrypted ${uri.scheme}:// to '
      '${uri.host}. Use https:// / wss://, or pass allowInsecureAuth: true '
      'for development only.';
}
