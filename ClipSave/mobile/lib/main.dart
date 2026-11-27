import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const ClipSave());

class ClipSave extends StatelessWidget {
  const ClipSave({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ClipSave',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff006b58)),
      useMaterial3: true,
    ),
    home: const DownloadPage(),
  );
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  static final defaultBackend = const String.fromEnvironment('CLIPSAVE_API_URL')
      .replaceFirst(RegExp(r'/+$'), '');
  final url = TextEditingController();
  final api = Dio(
    BaseOptions(
      baseUrl: defaultBackend,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 85),
      followRedirects: false,
    ),
  );

  List<File> saved = [];
  Map<String, dynamic>? preview;
  String? inspectedUrl;
  String? quality;
  String? message;
  String? phase;
  double? progress;
  CancelToken? transfer;
  bool inspecting = false;
  bool failed = false;
  bool sharing = false;
  bool loadingSettings = true;

  @override
  void initState() {
    super.initState();
    loadHistory();
    loadSettings();
  }

  @override
  void dispose() {
    transfer?.cancel();
    url.dispose();
    if (transfer == null) api.close(force: true);
    super.dispose();
  }

  Future<Directory> videoFolder() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/clipsave').create(recursive: true);
  }

  Future<File> settingsFile() async =>
      File('${(await videoFolder()).path}/server.txt');

  bool validBackend(String address) {
    final endpoint = Uri.tryParse(address);
    return endpoint != null &&
        endpoint.host.isNotEmpty &&
        endpoint.userInfo.isEmpty &&
        !endpoint.hasQuery &&
        !endpoint.hasFragment &&
        (endpoint.scheme == 'https' ||
            (kDebugMode && endpoint.scheme == 'http'));
  }

  Future<void> loadSettings() async {
    try {
      final file = await settingsFile();
      if (!await file.exists()) return;
      final address = (await file.readAsString()).trim();
      if (mounted && validBackend(address)) api.options.baseUrl = address;
    } on FileSystemException {
      // A missing settings file uses the build's backend address.
    } catch (_) {
      // The configured backend is still usable without persistent settings.
    } finally {
      if (mounted) setState(() => loadingSettings = false);
    }
  }

  Future<void> editBackend() async {
    final initial = api.options.baseUrl;
    var address = initial;
    final form = GlobalKey<FormState>();
    final updated = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backend address'),
        content: Form(
          key: form,
          child: TextFormField(
            initialValue: initial,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Server URL'),
            onChanged: (value) =>
                address = value.trim().replaceFirst(RegExp(r'/+$'), ''),
            validator: (_) => validBackend(address)
                ? null
                : 'Enter a server URL. Release builds require HTTPS.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, address);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || updated == null || updated == initial) return;
    api.options.baseUrl = updated;
    resetPreview();
    try {
      await (await settingsFile()).writeAsString(updated, flush: true);
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Using this backend for this session. Could not save the address.',
        );
      }
    }
  }

  Future<void> loadHistory() async {
    try {
      final folder = await videoFolder();
      final videos = await folder
          .list()
          .where((entry) => entry is File && entry.path.endsWith('.mp4'))
          .cast<File>()
          .toList();
      videos.sort(
        (a, b) => b.uri.pathSegments.last.compareTo(a.uri.pathSegments.last),
      );
      if (mounted) setState(() => saved = videos);
    } catch (_) {
      if (mounted) setState(() => message = 'Could not read saved videos.');
    }
  }

  void resetPreview() => setState(() {
    preview = null;
    inspectedUrl = null;
    quality = null;
    message = null;
    failed = false;
  });

  String errorText(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['detail'] is String) {
        return data['detail'] as String;
      }
      if (error.response != null) {
        return 'The server could not complete the request. Try again.';
      }
      return 'Could not reach ClipSave. Check the backend address and your connection.';
    }
    if (error is FormatException) return error.message;
    if (error is FileSystemException) {
      return 'Could not save or delete the video. Check device storage.';
    }
    return 'Something went wrong. Try again.';
  }

  Future<void> inspect() async {
    final input = url.text.trim();
    final link = Uri.tryParse(input);
    if (!validBackend(api.options.baseUrl)) {
      setState(() => message = 'Enter your backend address in Settings.');
      return;
    }
    if (link == null ||
        link.host.isEmpty ||
        !['http', 'https'].contains(link.scheme)) {
      setState(() => message = 'Paste a direct MP4 or YouTube Shorts link.');
      return;
    }
    if (inspecting || transfer != null) return;
    resetPreview();
    setState(() => inspecting = true);
    try {
      final result = await api.post<Map<String, dynamic>>(
        '/inspect',
        data: {'url': input},
      );
      final data = result.data!;
      final choices = data['qualities'] as List;
      if (choices.isEmpty) {
        throw const FormatException('No MP4 quality is available.');
      }
      if (!mounted) return;
      setState(() {
        preview = data;
        inspectedUrl = input;
        quality = (choices.first as Map)['id'] as String;
      });
    } catch (error) {
      if (mounted) setState(() => message = errorText(error));
    } finally {
      if (mounted) setState(() => inspecting = false);
    }
  }

  Future<void> discardJob(String id) async {
    try {
      await api.delete<void>('/jobs/$id').timeout(const Duration(seconds: 5));
    } catch (_) {
      // The server expires jobs when cleanup cannot reach it.
    }
  }

  Future<void> download() async {
    final source = inspectedUrl;
    final selected = quality;
    if (source == null || selected == null || transfer != null) return;
    final cancellation = CancelToken();
    final title = preview!['title'] as String;
    setState(() {
      transfer = cancellation;
      phase = 'Preparing video';
      progress = null;
      message = null;
      failed = false;
    });
    String? id;
    File? partial;
    File? completed;
    try {
      // Wait for the job ID so cancellation can stop a job created in flight.
      final start = await api.post<Map<String, dynamic>>(
        '/jobs',
        data: {'url': source, 'quality': selected},
      );
      id = start.data!['id'] as String;
      while (!cancellation.isCancelled) {
        final response = await api.get<Map<String, dynamic>>(
          '/jobs/$id',
          cancelToken: cancellation,
        );
        final status = response.data!;
        switch (status['state']) {
          case 'completed':
            break;
          case 'failed':
          case 'canceled':
            throw FormatException(
              status['error'] as String? ?? 'The download was canceled.',
            );
          default:
            final ratio = (status['progress'] as num?)?.toDouble();
            if (mounted) {
              setState(() {
                phase = switch (status['state']) {
                  'downloading' => 'Downloading from source',
                  'processing' => 'Preparing MP4',
                  _ => 'Preparing video',
                };
                progress = ratio;
              });
            }
            await Future<void>.delayed(const Duration(milliseconds: 500));
            continue;
        }
        break;
      }
      if (cancellation.isCancelled) return;
      final folder = await videoFolder();
      final clean = title
          .replaceAll(RegExp(r'[^p{L}p{N} ._-]', unicode: true), '_')
          .trim();
      final short = String.fromCharCodes(clean.runes.take(45));
      final stem = short.isEmpty ? 'Video' : short;
      final path =
          '${folder.path}/${DateTime.now().microsecondsSinceEpoch}-$stem.mp4';
      if (cancellation.isCancelled) return;
      partial = File('$path.part');
      if (mounted) {
        setState(() {
          phase = 'Saving to device';
          progress = null;
        });
      }
      await api.download(
        '/jobs/$id/file',
        partial.path,
        cancelToken: cancellation,
        onReceiveProgress: (received, total) {
          if (mounted && !cancellation.isCancelled && total > 0) {
            setState(() => progress = received / total);
          }
        },
      );
      if (cancellation.isCancelled) return;
      completed = await partial.rename(path);
      await loadHistory();
      if (mounted) setState(() => message = 'Video saved.');
    } catch (error) {
      if (mounted && !cancellation.isCancelled) {
        setState(() {
          message = errorText(error);
          failed = true;
        });
      }
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        // An interrupted transfer is excluded from the saved history.
      }
      if (id != null) await discardJob(id);
      if (mounted) {
        setState(() {
          transfer = null;
          phase = null;
          progress = null;
          if (cancellation.isCancelled && completed == null) {
            message = 'Download canceled.';
          }
        });
      } else {
        api.close(force: true);
      }
    }
    if (mounted && completed != null && !cancellation.isCancelled) {
      await share(completed);
    }
  }

  void cancel() {
    final active = transfer;
    if (active == null || active.isCancelled) return;
    active.cancel();
    setState(() {
      phase = 'Canceling';
      progress = null;
    });
  }

  String displayName(File video) =>
      video.uri.pathSegments.last.replaceFirst(RegExp(r'^d+-'), '');

  Future<void> share(File video) async {
    if (sharing) return;
    setState(() => sharing = true);
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null && box.hasSize
          ? (box.localToGlobal(box.size.center(Offset.zero)) & const Size(1, 1))
          : const Rect.fromLTWH(1, 1, 1, 1);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(video.path, mimeType: 'video/mp4')],
          fileNameOverrides: [displayName(video)],
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not open the share sheet. Try sharing from Saved videos.',
        );
      }
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  Future<void> deleteVideo(File video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete saved video?'),
        content: Text(displayName(video)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await video.delete();
      await loadHistory();
    } catch (error) {
      if (mounted) setState(() => message = errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = loadingSettings || inspecting || transfer != null;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final data = preview;
    final activity = inspecting ? 'Checking link…' : phase;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset('assets/clipsave.png', width: 36, height: 36),
            ),
            const SizedBox(width: 10),
            const Text('ClipSave'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: busy || sharing ? null : editBackend,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              children: [
                if (!loadingSettings && !validBackend(api.options.baseUrl))
                  Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    child: ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: const Text('Connect to your backend'),
                      subtitle: const Text(
                        'Set the server address to start downloading.',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: editBackend,
                    ),
                  ),
                TextField(
                  controller: url,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  onChanged: (_) => resetPreview(),
                  onSubmitted: (_) => inspect(),
                  decoration: InputDecoration(
                    labelText: 'Video link',
                    hintText: 'Direct MP4 or YouTube Shorts',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'Paste link',
                      icon: const Icon(Icons.content_paste),
                      onPressed: busy
                          ? null
                          : () async {
                              final value = await Clipboard.getData(
                                Clipboard.kTextPlain,
                              );
                              if (!mounted ||
                                  inspecting ||
                                  transfer != null ||
                                  value?.text == null) {
                                return;
                              }
                              url.text = value!.text!.trim();
                              resetPreview();
                            },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : inspect,
                  icon: const Icon(Icons.link_rounded),
                  label: const Text('Preview link'),
                ),
                if (data != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: SizedBox(
                        width: 54,
                        height: 54,
                        child: data['thumbnail'] is String
                            ? Image.network(
                                data['thumbnail'] as String,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.movie_outlined),
                              )
                            : const Icon(Icons.movie_outlined),
                      ),
                      title: Text(
                        data['title'] as String,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('MP4 video'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Quality',
                      border: OutlineInputBorder(),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isDense: true,
                        isExpanded: true,
                        value: quality,
                        items: (data['qualities'] as List)
                            .map(
                              (item) => DropdownMenuItem<String>(
                                value: item['id'] as String,
                                child: Text(item['label'] as String),
                              ),
                            )
                            .toList(),
                        onChanged: busy
                            ? null
                            : (value) => setState(() => quality = value),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: Icon(failed ? Icons.refresh : Icons.download),
                    onPressed: busy || sharing ? null : download,
                    label: Text(failed ? 'Retry download' : 'Download MP4'),
                  ),
                ],
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: activity == null
                      ? const SizedBox.shrink()
                      : _LoadingCard(
                          label: activity,
                          progress: inspecting ? null : progress,
                          canCancel: phase != null,
                          onCancel: transfer?.isCancelled == true
                              ? null
                              : cancel,
                        ),
                ),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Semantics(liveRegion: true, child: Text(message!)),
                  ),
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                Text('Saved videos', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                if (saved.isEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.video_library_outlined,
                      color: colors.onSurfaceVariant,
                    ),
                    title: const Text('Your downloaded MP4s will appear here.'),
                  ),
                for (final video in saved)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      displayName(video),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Share video',
                          onPressed: busy || sharing
                              ? null
                              : () => share(video),
                          icon: const Icon(Icons.ios_share),
                        ),
                        IconButton(
                          tooltip: 'Delete video',
                          onPressed: busy || sharing
                              ? null
                              : () => deleteVideo(video),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({
    required this.label,
    required this.progress,
    required this.canCancel,
    required this.onCancel,
  });

  final String label;
  final double? progress;
  final bool canCancel;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = progress?.clamp(0.0, 1.0).toDouble();
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(label, style: theme.textTheme.titleSmall),
                  ),
                ),
                if (ratio != null) Text('${(ratio * 100).round()}%'),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: ratio, minHeight: 6),
            ),
            if (canCancel)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel download'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
