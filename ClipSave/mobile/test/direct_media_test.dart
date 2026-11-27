import 'dart:io';

import 'package:clipsave/direct_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct transfers reject local, reserved, and non-IPv4 addresses', () {
    for (final value in ['127.0.0.1', '10.1.2.3', '169.254.169.254',
        '172.16.0.1', '192.168.0.1', '100.64.0.1', '224.0.0.1',
        '198.51.100.1', '::1', '::ffff:127.0.0.1']) {
      expect(DirectMedia.isPublicIPv4(InternetAddress(value)), isFalse, reason: value);
    }
    expect(DirectMedia.isPublicIPv4(InternetAddress('1.1.1.1')), isTrue);
  });

  test('direct preview requires a public HTTPS MP4 source', () async {
    for (final value in ['http://example.org/clip.mp4',
        'https://example.org:8443/clip.mp4', 'https://user@example.org/clip.mp4',
        'https://youtube.com/shorts/123']) {
      await expectLater(DirectMedia.preview(Uri.parse(value)), throwsFormatException);
    }
  });
}
