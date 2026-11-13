import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../book_identity.dart';
import '../book_search.dart';
import '../catalog.dart';
import '../tag_catalogue.dart';
import 'source_store.dart';
import 'source_media.dart';

class SourceBridge {
  const SourceBridge();
  static const channel = MethodChannel('org.mewx.wenku8/legado');
  Future<dynamic> call(String method, Map<String, dynamic> args) async {
    try {
      return await channel.invokeMethod<dynamic>(method, args);
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? '书源执行失败');
    } on MissingPluginException {
      throw const FormatException('阅读书源目前支持 Android，请安装 Android 版本');
    }
  }

  Future<String> fetch(String url) async =>
      await call('fetch', {'url': url}) as String;
}

class SourceRepository extends NovelRepository
    implements ProgressiveTagCatalogue, SourceChangeProvider {
  @override
  Listenable get sourceChanges => store;
  SourceRepository({
    required this.legacy,
    required this.store,
    this.bridge = const SourceBridge(),
  });
  final NovelRepository legacy;
  final SourceStore store;
  final SourceBridge bridge;
  Novel _novel(Map<String, dynamic> record) => Novel(
    id: record['id'] as int,
    title: '${record['title'] ?? '未命名'}',
    author: '${record['author'] ?? ''}',
    genre: '${record['genre'] ?? ''}',
    summary: '${record['summary'] ?? ''}',
    colors: const [Color(0xFF5E6B69), Color(0xFF293C3A)],
    coverUrl: (record['coverUrl'] as String?)?.isEmpty == false
        ? record['coverUrl'] as String
        : null,
    lastUpdate: record['lastUpdate'] as String?,
  );
  Map<String, dynamic> _book(int id) =>
      store.book(id) ??
      (throw const FormatException('书源书籍索引缺失，请恢复包含书源的备份或重新搜索'));
  BookSource _source(Map<String, dynamic> book) =>
      store.source(book['source'] as String) ??
      (throw const FormatException('原书源已删除，请重新导入后重试'));
  Future<List<Map<String, dynamic>>> _books(
    String method,
    BookSource source, {
    String query = '',
    int page = 1,
  }) async {
    final response =
        await bridge.call(method, {
              'source': source.json,
              'query': query,
              'page': page,
            })
            as Map;
    return store.rememberBooks(
      source,
      (response['items'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }

  @override
  Future<List<Novel>> list() async => (await browse()).items;
  @override
  Future<List<Novel>> search(String query) async =>
      (await searchPage(query)).items;
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    final source = store.active;
    if (source == null) {
      return legacy.browse(sort: sort, page: page, refresh: refresh);
    }
    if (!source.hasExplore) {
      return NovelPage(items: const [], page: page, totalPages: page);
    }
    final books = await _books('browse', source, page: page);
    return NovelPage(
      items: books.map(_novel).toList(),
      page: page,
      totalPages: books.isEmpty ? page : null,
    );
  }

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    final source = store.active;
    if (source == null) {
      return legacy.searchPage(query, page: page, refresh: refresh);
    }
    final books = await _books('search', source, query: query, page: page);
    // Sources without a page variable must not repeat the same search forever.
    final paged = '${source.json['searchUrl']}'.contains('page');
    return NovelPage(
      items: books.map(_novel).toList(),
      page: page,
      totalPages: !paged || books.isEmpty ? page : null,
    );
  }

  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) {
    if (store.active == null) {
      return legacy.searchFilteredPage(
        query,
        field: field,
        page: page,
        refresh: refresh,
      );
    }
    return searchPage(query, page: page, refresh: refresh);
  }

  @override
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
  }) {
    if (store.active == null && legacy is ProgressiveTagCatalogue) {
      return (legacy as ProgressiveTagCatalogue).tagPage(
        tag,
        page: page,
        refresh: refresh,
        current: current,
      );
    }
    return searchPage(tag, page: page, refresh: refresh);
  }

  @override
  Future<Novel?> find(int id) async => isSourceBook(id)
      ? (store.book(id) == null ? null : _novel(_book(id)))
      : legacy.find(id);
  @override
  Future<Novel> detail(Novel novel) async {
    if (!isSourceBook(novel.id)) return legacy.detail(novel);
    final book = _book(novel.id), source = _source(_book(novel.id));
    final raw = Map<String, dynamic>.from(
      await bridge.call('detail', {'source': source.json, 'book': book}) as Map,
    );
    return _novel((await store.rememberBooks(source, [raw])).single);
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    if (!isSourceBook(id)) return legacy.chapters(id);
    var book = _book(id);
    if ('${book['tocUrl'] ?? ''}'.isEmpty) {
      await detail(_novel(book));
      book = _book(id);
    }
    final response =
        await bridge.call('chapters', {
              'source': _source(book).json,
              'book': book,
            })
            as List;
    final records = await store.rememberChapters(
      id,
      response.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
    );
    return records
        .map(
          (c) => NovelChapter(
            '${c['title']}',
            '',
            id: c['id'] as int,
            volumeTitle: '${c['volumeTitle'] ?? ''}',
          ),
        )
        .toList();
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (!isSourceBook(novelId)) return legacy.chapterContent(novelId, chapter);
    final book = _book(novelId),
        address = store.chapterUrl(novelId, chapter.id);
    if (address.isEmpty) throw const FormatException('章节地址缺失，请联网刷新目录');
    final order =
        (book['chapterOrder'] as List?)?.cast<String>() ?? const <String>[];
    final position = order.indexOf(address);
    final content =
        await bridge.call('content', {
              'source': _source(book).json,
              'book': book,
              if (position >= 0 && position + 1 < order.length)
                'nextChapterUrl': order[position + 1],
              'chapter': {
                'url': address,
                'title': chapter.title,
                'index': position >= 0 ? position : 0,
              },
            })
            as String;
    return content.replaceAllMapped(
      RegExp(r'<!--image-->(.*?)<!--image-->', dotAll: true),
      (m) =>
          '<!--image-->${SourceMedia.reference(novelId, m[1]!.trim())}<!--image-->',
    );
  }
}
