import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

class DirectMedia {
  static const maxBytes = 100 * 1024 * 1024;
  static const _prefixLength = 12;

  static bool isYouTube(Uri url) {
    final host = url.host.toLowerCase();
    return host == 'youtu.be' || host == 'youtube.com' ||
        host.endsWith('.youtube.com');
  }

  static bool isPublicIPv4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && (b[1] == 168 ||
            (b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
            (b[1] == 88 && b[2] == 99))) ||
        (b[0] == 198 && (b[1] == 18 || b[1] == 19 ||
            (b[1] == 51 && b[2] == 100))) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113));
  }

  static void _validateUrl(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty ||
        uri.authority.contains('@') || uri.port != 443 || isYouTube(uri)) {
      throw const FormatException('Use a public HTTPS link to an MP4 video.');
    }
  }

  static Future<String> preview(Uri uri) async {
    final title = await _transfer(uri);
    return title.isEmpty ? 'Video' : title;
  }

  static Future<void> download(
    Uri uri,
    File partial,
    CancelToken cancellation,
    void Function(int, int?) onProgress,
  ) async {
    await _transfer(uri, partial: partial, cancellation: cancellation, onProgress: onProgress);
  }

  static Future<String> _transfer(
    Uri uri, {
    File? partial,
    CancelToken? cancellation,
    void Function(int, int?)? onProgress,
  }) async {
    _validateUrl(uri);
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (url, _, _) async {
        final candidates = await InternetAddress.lookup(
          url.host, type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 10));
        if (candidates.isEmpty || candidates.any((address) => !isPublicIPv4(address))) {
          throw const FormatException('The link must point to a public video server.');
        }
        return Socket.startConnect(candidates.first, url.port);
      };
    var timedOut = false;
    final deadline = Timer(Duration(seconds: partial == null ? 25 : 240), () {
      timedOut = true;
      client.close(force: true);
    });
    var active = true;
    if (cancellation != null) {
      if (cancellation.isCancelled) {
        client.close(force: true);
      } else {
        unawaited(cancellation.whenCancel.then((_) {
          if (active) client.close(force: true);
        }));
      }
    }
    IOSink? output;
    try {
      for (var hop = 0; hop < 6; hop++) {
        _validateUrl(uri);
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (partial == null) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-11');
        }
        final response = await request.close();
        final status = response.statusCode;
        if ([301, 302, 303, 307, 308].contains(status)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || location.isEmpty) break;
          // Cancel the response body before connecting to the next host.
          final subscription = response.listen(null);
          await subscription.cancel();
          uri = uri.resolve(location);
          continue;
        }
        if (status != 200 && !(partial == null && status == 206)) {
          throw FormatException('The video source is unavailable (HTTP $status).');
        }
        final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          throw const FormatException('The server returned an unsupported encoding.');
        }
        final type = response.headers.contentType?.mimeType;
        if (type != null && !['video/mp4', 'application/mp4',
            'application/octet-stream', 'binary/octet-stream'].contains(type)) {
          throw const FormatException('This link did not return an MP4 video.');
        }
        final range = response.headers.value(HttpHeaders.contentRangeHeader);
        if (status == 206 && !(range?.startsWith('bytes 0-') ?? false)) {
          throw const FormatException('The server returned an invalid MP4 range.');
        }
        final size = status == 206
            ? int.tryParse(range?.split('/').last ?? '')
            : response.contentLength;
        if (size != null && size > maxBytes) {
          throw const FormatException('The video exceeds the 100 MB limit.');
        }

        final prefix = <int>[];
        var received = 0;
        await for (final chunk in response.timeout(const Duration(seconds: 15))) {
          if (output == null) {
            final missing = _prefixLength - prefix.length;
            prefix.addAll(chunk.take(missing));
            if (prefix.length < _prefixLength) continue;
            if (String.fromCharCodes(prefix.sublist(4, 8)) != 'ftyp') {
              throw const FormatException('This link did not return an MP4 video.');
            }
            if (partial == null) break;
            output = partial.openWrite();
            output.add(prefix);
            output.add(chunk.sublist(missing));
            received = prefix.length + chunk.length - missing;
          } else {
            received += chunk.length;
            if (received <= maxBytes) output.add(chunk);
          }
          if (received > maxBytes) {
            throw const FormatException('The video exceeds the 100 MB limit.');
          }
          await output.flush();
          onProgress?.call(received, size != null && size > 0 ? size : null);
        }
        if (prefix.length < _prefixLength ||
            (partial != null && size != null && size > 0 && received != size)) {
          throw const FormatException('The MP4 transfer ended early. Try again.');
        }
        final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
        return name.replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), '');
      }
      throw const FormatException('The video link redirected too many times or is invalid.');
    } on TimeoutException {
      throw const FormatException('The video source timed out. Try again.');
    } on IOException catch (error) {
      if (error is FileSystemException) rethrow;
      if (timedOut) {
        throw const FormatException('The video source timed out. Try again.');
      }
      throw const FormatException('Could not reach the public video server.');
    } finally {
      active = false;
      deadline.cancel();
      client.close(force: true);
      await output?.close();
    }
  }
}
