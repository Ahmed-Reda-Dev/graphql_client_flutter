import 'codegen_exception.dart';

/// Whether [url] is an http(s) URL with a host.
bool isHttpUrl(Uri url) =>
    (url.scheme == 'http' || url.scheme == 'https') && url.host.isNotEmpty;

/// The command-line options of `dart run graphql_client_flutter:generate`.
final class CliOptions {
  /// Creates options.
  const CliOptions({
    this.help = false,
    this.watch = false,
    this.download = false,
    this.downloadUrl,
    this.headers = const {},
  });

  /// Parses [args]. Throws a [CodegenException] for an unknown or
  /// incomplete option.
  factory CliOptions.parse(List<String> args) {
    var help = false;
    var watch = false;
    var download = false;
    Uri? downloadUrl;
    final headers = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String? next() => i + 1 < args.length && !args[i + 1].startsWith('-')
          ? args[++i]
          : null;
      switch (arg) {
        case '-h' || '--help':
          help = true;
        case '-w' || '--watch':
          watch = true;
        case '--download':
          download = true;
          if (next() case final url?) {
            downloadUrl = Uri.tryParse(url);
            if (downloadUrl == null || !downloadUrl.hasScheme) {
              throw CodegenException('--download needs a URL, got "$url"');
            }
            if (!isHttpUrl(downloadUrl)) {
              throw CodegenException(
                '--download needs an http:// or https:// URL, got "$url"',
              );
            }
          }
        case '--header':
          final header = next();
          final colon = header?.indexOf(':') ?? -1;
          if (header == null || colon <= 0) {
            throw const CodegenException(
              '--header needs "Name: value", e.g. '
              '--header "Authorization: Bearer \$TOKEN"',
            );
          }
          headers[header.substring(0, colon).trim()] =
              header.substring(colon + 1).trim();
        default:
          throw CodegenException('Unknown option "$arg"; see --help');
      }
    }
    if (headers.isNotEmpty && !download) {
      throw const CodegenException('--header is used only with --download');
    }
    return CliOptions(
      help: help,
      watch: watch,
      download: download,
      downloadUrl: downloadUrl,
      headers: headers,
    );
  }

  /// Whether to print the usage.
  final bool help;

  /// Whether to keep regenerating when documents or the schema change.
  final bool watch;

  /// Whether to download the schema before generating.
  final bool download;

  /// Where to download it from (else the `schema_url` setting).
  final Uri? downloadUrl;

  /// Headers sent with the download, e.g. `Authorization`.
  final Map<String, String> headers;
}
