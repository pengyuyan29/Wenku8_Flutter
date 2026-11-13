import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class OptionalFontFile {
  const OptionalFontFile(this.name, this.bytes, this.sha256sum, this.urls);
  final String name, sha256sum;
  final int bytes;
  final List<String> urls;
}

const sourceHanFiles = [
  OptionalFontFile(
    'SourceHanSerifCN-Regular.otf',
    11626108,
    '3754ea669c530e2473354f8f6d9f79680a44d7e26ec7d00eeabee4a7e0753c5d',
    [
      'https://raw.githubusercontent.com/adobe-fonts/source-han-serif/2.003R/SubsetOTF/CN/SourceHanSerifCN-Regular.otf',
      'https://cdn.jsdelivr.net/gh/adobe-fonts/source-han-serif@2.003R/SubsetOTF/CN/SourceHanSerifCN-Regular.otf',
    ],
  ),
  OptionalFontFile(
    'SourceHanSerifCN-Bold.otf',
    12094680,
    '4ee555ae58b3d22f6a95c2c494f2c36b7cccfc1d2224635f6461a03756f0e3c1',
    [
      'https://raw.githubusercontent.com/adobe-fonts/source-han-serif/2.003R/SubsetOTF/CN/SourceHanSerifCN-Bold.otf',
      'https://cdn.jsdelivr.net/gh/adobe-fonts/source-han-serif@2.003R/SubsetOTF/CN/SourceHanSerifCN-Bold.otf',
    ],
  ),
];

/// Explicit opt-in downloads. A verified two-face pack is published atomically
/// by its completion marker; neither launch nor font preview starts a request.
class OptionalFontPack extends ChangeNotifier {
  OptionalFontPack({
    Directory? directory,
    this.files = sourceHanFiles,
    HttpClient Function()? clientFactory,
  }) : _directory = directory,
       _clientFactory = clientFactory ?? HttpClient.new;
  Directory? _directory;
  final List<OptionalFontFile> files;
  final HttpClient Function() _clientFactory;
  HttpClient? _client;
  Future<bool>? _pending;
  Future<void>? _loading;
  bool _ready = false, _cancelled = false, _disposed = false;
  bool get ready => _ready;
  bool get downloading => _pending != null;
  bool get cancelled => _cancelled;
  int received = 0;
  String? error;
  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes);
  double get progress =>
      totalBytes == 0 ? 0 : (received / totalBytes).clamp(0, 1);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<Directory> get directory async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/optional-fonts/source-han-serif-2.003R',
  );
  Future<List<File>> get fontFiles async {
    final root = await directory;
    return files.map((f) => File('${root.path}/${f.name}')).toList();
  }

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    final root = await directory;
    final marker = File('${root.path}/ready.json');
    if (!await marker.exists()) return;
    try {
      if (await marker.length() > 4096) return;
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map ||
          value['version'] != 1 ||
          !listEquals(
            (value['hashes'] as List?)?.cast<String>(),
            files.map((f) => f.sha256sum).toList(),
          )) {
        return;
      }
      for (final spec in files) {
        final file = File('${root.path}/${spec.name}');
        if (!await file.exists() ||
            await file.length() != spec.bytes ||
            await compute(_fontHash, file.path) != spec.sha256sum) {
          return;
        }
      }
      _ready = true;
    } on FormatException {
      _ready = false;
    } on FileSystemException {
      _ready = false;
    } on TypeError {
      _ready = false;
    }
  }

  Future<bool> download() {
    if (_pending != null) return _pending!;
    if (_ready) return Future.value(true);
    _cancelled = false;
    error = null;
    received = 0;
    final future = _download();
    _pending = future;
    _notify();
    return future;
  }

  void cancel() {
    if (!downloading) return;
    _cancelled = true;
    _client?.close(force: true);
    _notify();
  }

  Future<bool> _download() async {
    // Yield so _pending is installed before completion or cancellation.
    await Future<void>.value();
    Directory? root;
    try {
      root = await directory;
      await root.create(recursive: true);
      var completed = 0;
      for (final spec in files) {
        final part = File('${root.path}/${spec.name}.part');
        Object? failure;
        var verified = false;
        for (final url in spec.urls) {
          if (_cancelled || _disposed) return false;
          received = completed;
          final client = _clientFactory();
          _client = client;
          IOSink? sink;
          try {
            final request = await client
                .getUrl(Uri.parse(url))
                .timeout(const Duration(seconds: 30));
            final response = await request.close().timeout(
              const Duration(seconds: 30),
            );
            if (response.statusCode != HttpStatus.ok) {
              throw const FormatException('字体下载失败，请检查网络后重试');
            }
            sink = part.openWrite();
            var count = 0;
            var lastNotice = DateTime.now();
            await for (final chunk in response.timeout(
              const Duration(seconds: 30),
            )) {
              if (_cancelled || _disposed) return false;
              count += chunk.length;
              if (count > spec.bytes) {
                throw const FormatException('字体文件大小不正确，请重试');
              }
              sink.add(chunk);
              // Await disk writes as well as the network; don't buffer the pack in RAM.
              await sink.flush();
              received = completed + count;
              final now = DateTime.now();
              if (now.difference(lastNotice).inMilliseconds >= 100) {
                _notify();
                lastNotice = now;
              }
            }
            await sink.close();
            sink = null;
            if (_cancelled || _disposed) return false;
            if (count != spec.bytes ||
                await compute(_fontHash, part.path) != spec.sha256sum) {
              throw const FormatException('字体文件校验失败，请重试');
            }
            verified = true;
            break;
          } catch (e) {
            if (_cancelled || _disposed) return false;
            failure = e;
          } finally {
            await sink?.close();
            client.close(force: true);
            _client = null;
          }
        }
        if (!verified) throw failure ?? const FormatException('字体下载失败，请重试');
        completed += spec.bytes;
        received = completed;
        _notify();
      }
      if (_cancelled || _disposed) return false;
      for (final spec in files) {
        await File(
          '${root.path}/${spec.name}.part',
        ).rename('${root.path}/${spec.name}');
      }
      await File('${root.path}/ready.json.part').writeAsString(
        jsonEncode({
          'version': 1,
          'hashes': files.map((f) => f.sha256sum).toList(),
        }),
        flush: true,
      );
      await File(
        '${root.path}/ready.json.part',
      ).rename('${root.path}/ready.json');
      _ready = true;
      return true;
    } catch (e) {
      if (!_cancelled && !_disposed) {
        error = e is FormatException ? e.message : '下载未完成，请检查网络或可用空间后重试';
      }
      return false;
    } finally {
      _client?.close(force: true);
      _client = null;
      if (root != null) {
        for (final name in [
          ...files.map((f) => '${f.name}.part'),
          'ready.json.part',
        ]) {
          final file = File('${root.path}/$name');
          try {
            if (await file.exists()) await file.delete();
          } on FileSystemException {
            /* Retry can overwrite a leftover part. */
          }
        }
      }
      _pending = null;
      _notify();
    }
  }

  Future<void> remove() async {
    if (downloading) {
      cancel();
      await _pending;
    }
    final root = await directory;
    if (await root.exists()) await root.delete(recursive: true);
    _ready = false;
    _loading = null;
    received = 0;
    error = null;
    _cancelled = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

Future<String> _fontHash(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();
