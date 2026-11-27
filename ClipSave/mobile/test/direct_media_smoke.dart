import 'dart:io';

import 'package:clipsave/direct_media.dart';
import 'package:dio/dio.dart';

Future<void> main() async {
  final url = Uri.parse(
    'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4',
  );
  final folder = await Directory.systemTemp.createTemp('clipsave-smoke-');
  final file = File('${folder.path}/flower.mp4.part');
  try {
    final title = await DirectMedia.preview(url);
    if (title.isEmpty) throw StateError('The preview title is empty.');
    var received = 0;
    await DirectMedia.download(url, file, CancelToken(), (bytes, _) {
      received = bytes;
    });
    if (received < 12 || await file.length() != received) {
      throw StateError('The downloaded file did not match transfer progress.');
    }
    stdout.writeln('Direct MP4 preview and download passed ($received bytes).');
  } finally {
    await folder.delete(recursive: true);
  }
}
