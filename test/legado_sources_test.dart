import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_identity.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legado/source_repository.dart';
import 'package:wenku8_flutter/legado/source_store.dart';
import 'package:wenku8_flutter/legado/source_media.dart';
import 'package:wenku8_flutter/legado/source_page.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/reader_content.dart';

Map<String, dynamic> sourceJson(String host) => {
  'bookSourceUrl': 'https://$host',
  'bookSourceName': host,
  'searchUrl': '/search?q={{key}}',
  'ruleSearch': {'bookList': 'class.book'},
  'ruleBookInfo': {'name': 'tag.h1@text'},
  'ruleToc': {'chapterList': 'tag.a'},
  'ruleContent': {'content': 'tag.article@html'},
};

class FixtureBridge extends SourceBridge {
  final calls = <String>[];
  bool fail = false;
  final delayed = <String, Completer<dynamic>>{};
  @override
  Future<dynamic> call(String method, Map<String, dynamic> args) async {
    calls.add(method);
    if (fail) throw const FormatException('fixture disconnected');
    final host = (args['source'] as Map)['bookSourceUrl'];
    if (delayed['$method:$host'] case final pending?) return pending.future;
    final book = {
      'url': '$host/book',
      'title': '测试小说',
      'author': '作者',
      'summary': '简介',
      'tocUrl': '$host/toc',
    };
    return switch (method) {
      'search' || 'browse' => {
        'items': [book],
      },
      'detail' => book,
      'chapters' => [
        {'url': '$host/c1', 'title': '第一章'},
        {'url': '$host/c2', 'title': '第二章'},
      ],
      'content' => '第一段\n\n<!--image-->$host/pic.jpg<!--image-->\n\n第二段',
      _ => throw UnimplementedError(method),
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late SourceStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = SourceStore(prefs);
  });
  tearDown(() {
    store.dispose();
    SourceMedia.store = null;
  });
  test(
    'imports one/list updates duplicates and rejects malformed sources atomically',
    () async {
      expect(await store.importText(jsonEncode(sourceJson('a.test'))), 1);
      expect(store.active, isNull);
      await store.select('https://a.test');
      expect(
        await store.importText(
          jsonEncode([sourceJson('a.test'), sourceJson('b.test')]),
        ),
        2,
      );
      expect(store.sources.length, 2);
      final saved = prefs.getString(legadoStoreKey);
      await expectLater(
        store.importText('[{"bookSourceName":"broken"}]'),
        throwsFormatException,
      );
      expect(prefs.getString(legadoStoreKey), saved);
      await store.enable('https://a.test', false);
      expect(store.active, isNull);
    },
  );
  test(
    'book collisions are resolved and chapter identities survive reorder and restart',
    () async {
      await store.importText(jsonEncode(sourceJson('a.test')));
      await store.select('https://a.test');
      final source = store.active!;
      final digest = sha256
          .convert(utf8.encode('${source.id}\nhttps://a.test/book'))
          .bytes;
      final collision =
          sourceBookIdStart +
          (((digest[0] << 24) |
                  (digest[1] << 16) |
                  (digest[2] << 8) |
                  digest[3]) &
              0x1fffffff);
      final record = SourceStore.decodeRecord(prefs.getString(legadoStoreKey));
      (record['books'] as Map)['$collision'] = {
        'id': collision,
        'source': source.id,
        'url': 'https://a.test/other',
        'title': '另一本',
        'chapterIds': {},
      };
      await prefs.setString(legadoStoreKey, jsonEncode(record));
      store.reload();
      final book = (await store.rememberBooks(source, [
        {'url': 'https://a.test/book', 'title': '小说'},
      ])).single;
      final id = book['id'] as int;
      expect(id, isNot(collision));
      expect(isSourceBook(id), isTrue);
      expect(isWenkuBook(id), isFalse);
      expect(isLocalBook(id), isFalse);
      final chapters = await store.rememberChapters(id, [
        {'url': 'https://a.test/c1'},
        {'url': 'https://a.test/c2'},
      ]);
      store.reload();
      final reordered = await store.rememberChapters(id, [
        {'url': 'https://a.test/c2'},
        {'url': 'https://a.test/c1'},
      ]);
      expect(
        reordered.map((c) => c['id']),
        chapters.reversed.map((c) => c['id']),
      );
    },
  );
  test(
    'selection does not redirect an existing book and cached content survives restart',
    () async {
      await store.importText(
        jsonEncode([sourceJson('a.test'), sourceJson('b.test')]),
      );
      await store.select('https://a.test');
      await store.enable('https://b.test', false);
      final bridge = FixtureBridge();
      final remote = SourceRepository(
        legacy: const DemoNovelRepository(),
        store: store,
        bridge: bridge,
      );
      final root = await Directory.systemTemp.createTemp('legado-cache-');
      addTearDown(() => root.delete(recursive: true));
      final cache = OfflineCacheStore(root);
      final offline = OfflineNovelRepository(remote: remote, cache: cache);
      addTearDown(offline.dispose);
      addTearDown(cache.dispose);
      final found = (await remote.search('测试')).single;
      await store.enable('https://a.test', false);
      await store.enable('https://b.test', true);
      final detail = await offline.detail(found);
      final chapters = await offline.chapters(found.id);
      expect(detail.id, found.id);
      await offline.rememberDirectory(detail.withChapters(chapters));
      final text = await offline.chapterContent(found.id, chapters.first);
      final marker = text.split('\n\n')[1];
      final image = readerIllustrationUrl(marker)!;
      expect(SourceMedia.valid(Uri.parse(image)), isTrue);
      expect(Uri.parse(image).queryParameters['url'], 'https://a.test/pic.jpg');
      expect(
        readerIllustrationUrl(
          '<!--image-->https://unrelated.test/pic.jpg<!--image-->',
        ),
        isNull,
      );
      final reloadedCache = OfflineCacheStore(root);
      addTearDown(reloadedCache.dispose);
      await reloadedCache.load();
      final reloadedStore = SourceStore(prefs);
      addTearDown(reloadedStore.dispose);
      final offlineAfterRestart = OfflineNovelRepository(
        remote: SourceRepository(
          legacy: const DemoNovelRepository(),
          store: reloadedStore,
          bridge: bridge,
        ),
        cache: reloadedCache,
      );
      addTearDown(offlineAfterRestart.dispose);
      bridge.fail = true;
      expect(
        await offlineAfterRestart.chapterContent(found.id, chapters.first),
        text,
      );
      expect(
        (await offlineAfterRestart.chapters(found.id)).map((c) => c.id),
        chapters.map((c) => c.id),
      );
    },
  );
  test(
    'normal backup restores source/book/chapter mapping without importing preferences',
    () async {
      await store.importText(jsonEncode(sourceJson('a.test')));
      await store.select('https://a.test');
      final book = (await store.rememberBooks(store.active!, [
        {'url': 'https://a.test/book', 'title': '小说'},
      ])).single;
      await store.rememberChapters(book['id'] as int, [
        {'url': 'https://a.test/c1'},
      ]);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final backup = await LibraryBackup.parse(
        await (await state.createBackup()).encode(),
      );
      expect(backup.records.containsKey(legadoStoreKey), isTrue);
      await prefs.remove(legadoStoreKey);
      store.reload();
      await state.restoreBackup(backup, importPreferences: false);
      store.reload();
      expect(store.source('https://a.test'), isNotNull);
      expect(store.book(book['id'] as int)?['url'], 'https://a.test/book');
      expect((store.book(book['id'] as int)!['chapterIds'] as Map).length, 1);
    },
  );
  test('incompatible backup identities fail before shelf changes', () async {
    await store.importText(jsonEncode(sourceJson('a.test')));
    await store.select('https://a.test');
    final book = (await store.rememberBooks(store.active!, [
      {'url': 'https://a.test/book', 'title': '小说'},
    ])).single;
    final conflicting = SourceStore.decodeRecord(
      prefs.getString(legadoStoreKey),
    );
    conflicting['books']['${book['id']}']['url'] = 'https://a.test/different';
    final backup = await LibraryBackup.fromRecords({
      legadoStoreKey: jsonEncode(conflicting),
      'shelf': ['12'],
    });
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    await expectLater(state.restoreBackup(backup), throwsFormatException);
    expect(state.shelf, isEmpty);
    expect(store.book(book['id'] as int)?['url'], 'https://a.test/book');
  });
  test('source changes invalidate in-flight search results', () async {
    await store.importText(
      jsonEncode([sourceJson('a.test'), sourceJson('b.test')]),
    );
    await store.select('https://a.test');
    final bridge = FixtureBridge();
    final pending = Completer<dynamic>();
    bridge.delayed['search:https://a.test'] = pending;
    final root = await Directory.systemTemp.createTemp('legado-feed-');
    addTearDown(() => root.delete(recursive: true));
    final cache = OfflineCacheStore(root);
    addTearDown(cache.dispose);
    final offline = OfflineNovelRepository(
      remote: SourceRepository(
        legacy: const DemoNovelRepository(),
        store: store,
        bridge: bridge,
      ),
      cache: cache,
    );
    addTearDown(offline.dispose);
    final feed = NovelFeedController(offline, search: true);
    addTearDown(feed.dispose);
    final old = feed.searchFor('测试');
    await store.enable('https://a.test', false);
    for (var i = 0; i < 30 && (feed.loading || feed.items.isEmpty); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(feed.items.length, 1);
    final selectedId = feed.items.single.id;
    pending.complete({
      'items': [
        {'url': 'https://a.test/old', 'title': '过期结果'},
      ],
    });
    await old;
    expect(feed.items.single.id, selectedId);
    expect(store.book(selectedId)?['source'], 'https://b.test');
  });
  test('search aggregates every enabled source and reports its channel', () async {
    await store.importText(
      jsonEncode([sourceJson('a.test'), sourceJson('b.test')]),
    );
    final bridge = FixtureBridge();
    final repository = SourceRepository(
      legacy: const DemoNovelRepository(),
      store: store,
      bridge: bridge,
    );
    final page = await repository.searchPage('测试');
    expect(page.items.length, 2);
    expect(
      page.items.map((book) => repository.channelNameOf(book.id)).toSet(),
      {'a.test', 'b.test'},
    );
    await store.enable('https://a.test', false);
    final remaining = await repository.searchPage('测试');
    expect(remaining.items.length, 1);
    expect(repository.channelNameOf(remaining.items.single.id), 'b.test');
  });
  test('bundled ordinary novel sources import and can be selected', () async {
    final text = await File('assets/sources/defaults.json').readAsString();
    expect(await store.importText(text), 3);
    await store.select('https://api.midukanshu.com');
    expect(store.active?.name, '米读看书');
    expect(store.sources.any((s) => s.id.contains('lnovel')), isFalse);
  });
  final providedFile = Platform.environment['LEGADO_SOURCE_FILE'];
  test(
    'provided subscription imports and fits the normal backup',
    () async {
      expect(
        await store.importText(await File(providedFile!).readAsString()),
        85,
      );
      expect(store.sources.length, 85);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final backup = await (await state.createBackup()).encode();
      expect(utf8.encode(backup).length, lessThan(LibraryBackup.maxBytes));
      expect(
        (await LibraryBackup.parse(backup)).records.containsKey(legadoStoreKey),
        isTrue,
      );
    },
    skip: providedFile == null,
  );
  testWidgets('source UI imports JSON and enables the source', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SourcePage(store: store, bridge: FixtureBridge()),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('source-input')),
      jsonEncode(sourceJson('a.test')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('source-import')));
      for (var i = 0; i < 50 && store.sources.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find
          .byType(SelectableText)
          .evaluate()
          .map((e) => (e.widget as SelectableText).data)
          .join(' '),
      isNot(contains('操作失败')),
    );
    expect(store.sources.length, 1);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('测试'), findsOneWidget);
    expect(store.sources.single.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
