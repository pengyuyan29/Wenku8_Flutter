import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/optional_fonts.dart';
import 'package:wenku8_flutter/user_fonts.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  late List<OptionalFontFile> specs;
  final regular = List<int>.generate(256 * 1024, (i) => i % 251);
  final bold = List<int>.generate(128 * 1024, (i) => i % 239);
  var requests = 0;
  var corrupt = false;
  var fail = false;
  Completer<void>? hold;
  Completer<void>? sent;
  setUp(() async {
    requests = 0;
    corrupt = false;
    fail = false;
    hold = null;
    sent = null;
    root = await Directory.systemTemp.createTemp('optional-font-download-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    specs = [
      OptionalFontFile(
        'regular.otf',
        regular.length,
        sha256.convert(regular).toString(),
        ['$base/missing', '$base/regular'],
      ),
      OptionalFontFile(
        'bold.otf',
        bold.length,
        sha256.convert(bold).toString(),
        ['$base/bold'],
      ),
    ];
    server.listen((request) async {
      requests++;
      try {
        if (request.uri.path == '/missing' || fail) {
          request.response.statusCode = 503;
          await request.response.close();
          return;
        }
        final data = request.uri.path == '/regular' ? regular : bold;
        final bytes = corrupt ? List<int>.filled(data.length, 0) : data;
        request.response.contentLength = bytes.length;
        if (hold != null) {
          request.response.add(bytes.take(bytes.length ~/ 2).toList());
          await request.response.flush();
          sent?.complete();
          await hold!.future;
          request.response.add(bytes.skip(bytes.length ~/ 2).toList());
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      } on IOException {
        /* A cancelled client is expected. */
      }
    });
  });
  tearDown(() async {
    if (hold != null && !hold!.isCompleted) hold!.complete();
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });
  OptionalFontPack pack() => OptionalFontPack(
    directory: root,
    files: specs,
    clientFactory: () => _RealHttp().createHttpClient(null),
  );
  test(
    'startup and font availability never initiate network requests',
    () async {
      final optional = pack();
      final fonts = UserFontStore(
        directory: Directory('${root.path}/custom'),
        optionalFonts: optional,
      );
      await fonts.load();
      expect(requests, 0);
      expect(fonts.available('sourceHanSerif'), isFalse);
      expect(fonts.available('system'), isTrue);
      expect(fonts.family('sourceHanSerif'), isNull);
      await fonts.ensureLoaded('sourceHanSerif');
      expect(requests, 0);
      SharedPreferences.setMockInitialValues({});
      final state = LibraryState(
        await SharedPreferences.getInstance(),
        fonts: fonts,
      );
      addTearDown(state.dispose);
      expect(state.appFontId, 'system');
      expect(state.readerFontId, 'system');
      await expectLater(
        state.setAppFont('sourceHanSerif'),
        throwsFormatException,
      );
      // The state owns the store, so avoid disposing twice.
    },
  );
  test(
    'two validated weights commit together, use a mirror and survive offline restart',
    () async {
      final first = pack();
      addTearDown(first.dispose);
      final pending = first.download();
      expect(identical(pending, first.download()), isTrue);
      expect(await pending, isTrue);
      expect(requests, 3);
      expect(first.ready, isTrue);
      expect(first.progress, 1);
      final second = pack();
      addTearDown(second.dispose);
      await second.load();
      expect(second.ready, isTrue);
      expect(requests, 3);
      expect(await second.download(), isTrue);
      expect(requests, 3);
      await second.remove();
      expect(second.ready, isFalse);
      expect(await File('${root.path}/regular.otf').exists(), isFalse);
    },
  );
  test(
    'network failure leaves no selectable pack and retries cleanly',
    () async {
      final optional = pack();
      addTearDown(optional.dispose);
      fail = true;
      expect(await optional.download(), isFalse);
      expect(optional.ready, isFalse);
      expect(optional.error, contains('下载失败'));
      expect(await File('${root.path}/ready.json').exists(), isFalse);
      fail = false;
      expect(await optional.download(), isTrue);
    },
  );
  test('bad checksum is not selectable and can be retried', () async {
    final optional = pack();
    addTearDown(optional.dispose);
    corrupt = true;
    expect(await optional.download(), isFalse);
    expect(optional.error, contains('校验'));
    expect(optional.ready, isFalse);
    expect(await File('${root.path}/ready.json').exists(), isFalse);
    expect(await root.list().where((f) => f.path.endsWith('.part')).length, 0);
    corrupt = false;
    expect(await optional.download(), isTrue);
    expect(optional.ready, isTrue);
  });
  test(
    'cancelling an in-flight download cleans partials and permits retry',
    () async {
      final optional = pack();
      addTearDown(optional.dispose);
      hold = Completer<void>();
      sent = Completer<void>();
      final download = optional.download();
      await sent!.future;
      optional.cancel();
      hold!.complete();
      expect(await download, isFalse);
      expect(optional.cancelled, isTrue);
      expect(optional.ready, isFalse);
      expect(optional.downloading, isFalse);
      expect(
        await root.list().where((f) => f.path.endsWith('.part')).length,
        0,
      );
      hold = null;
      sent = null;
      expect(await optional.download(), isTrue);
    },
  );
  test(
    'damaged cached bytes fall back to system and never trigger auto-download',
    () async {
      final downloaded = pack();
      addTearDown(downloaded.dispose);
      expect(await downloaded.download(), isTrue);
      final before = requests;
      await File(
        '${root.path}/regular.otf',
      ).writeAsBytes(List.filled(regular.length, 0));
      final fonts = UserFontStore(
        directory: Directory('${root.path}/custom'),
        optionalFonts: pack(),
        loader: (_, _) async {},
      );
      SharedPreferences.setMockInitialValues({
        'appTypeface': 'sourceHanSerif',
        'readerTypeface': 'sourceHanSerif',
      });
      final state = LibraryState(
        await SharedPreferences.getInstance(),
        fonts: fonts,
      );
      addTearDown(state.dispose);
      await state.loadFonts();
      expect(state.appFontChoice, 'system');
      expect(state.readerFontId, 'system');
      expect(requests, before);
    },
  );
  test(
    'selecting and deleting downloaded fonts resets both active consumers',
    () async {
      final optional = pack();
      expect(await optional.download(), isTrue);
      final fonts = UserFontStore(
        directory: Directory('${root.path}/custom'),
        optionalFonts: optional,
        loader: (_, _) async {},
      );
      SharedPreferences.setMockInitialValues({});
      final state = LibraryState(
        await SharedPreferences.getInstance(),
        fonts: fonts,
      );
      addTearDown(state.dispose);
      await state.loadFonts();
      await state.setAppFont('sourceHanSerif');
      await state.setReaderTypeface('sourceHanSerif');
      expect(state.appFontFamily, 'SourceHanSerifCN');
      var changes = 0;
      state.applicationChanges.addListener(() => changes++);
      await state.removeUserFont('sourceHanSerif');
      expect(state.appFontId, 'system');
      expect(state.readerFontId, 'system');
      expect(changes, greaterThan(0));
    },
  );
  test('font binaries are excluded from application assets', () async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    expect(manifest.any((f) => f['family'] == 'SourceHanSerifCN'), isFalse);
    final assets = (await AssetManifest.loadFromAssetBundle(
      rootBundle,
    )).listAssets();
    expect(
      assets.any((p) => p.endsWith('.otf') && p.contains('SourceHanSerif')),
      isFalse,
    );
  });
  test(
    'official optional font files download and verify end to end',
    () async {
      final optional = OptionalFontPack(
        directory: root,
        clientFactory: () =>
            _RealHttp().createHttpClient(null)
              ..findProxy = HttpClient.findProxyFromEnvironment,
      );
      addTearDown(optional.dispose);
      expect(await optional.download(), isTrue, reason: optional.error);
      expect(optional.ready, isTrue);
      expect((await optional.fontFiles).length, 2);
    },
    skip: Platform.environment['VERIFY_ONLINE_FONTS'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
