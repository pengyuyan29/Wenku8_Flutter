import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../book_identity.dart';

const legadoStoreKey = 'legado_library_v1';
const defaultSourceSubscription =
    'https://shuyuan.nyasama.net/shuyuan/f7fc76e0da51eec18490ea226ac43ba3.json';

class BookSource {
  BookSource(Map<String, dynamic> value) : json = Map.unmodifiable(value);
  final Map<String, dynamic> json;
  String get id => json['bookSourceUrl'] as String;
  String get name => json['bookSourceName'] as String;
  bool get enabled => json['enabled'] != false;
  bool get hasExplore => '${json['exploreUrl'] ?? ''}'.trim().isNotEmpty;
}

/// Persistent collision-checked identities, independent of list/directory order.
/// The complete record travels with the normal reading-record backup.
class SourceStore extends ChangeNotifier {
  SourceStore(this.preferences) {
    reload(notify: false);
  }
  final SharedPreferences preferences;
  Map<String, dynamic> _data = emptyRecord();
  Future<void> _writes = Future.value();
  String? _encoded;
  void _sync() {
    final latest = preferences.getString(legadoStoreKey);
    if (latest != _encoded) {
      _data = decodeRecord(latest);
      _encoded = latest;
    }
  }

  static Map<String, dynamic> emptyRecord() => {
    'version': 1,
    'active': null,
    'sources': <dynamic>[],
    'books': <String, dynamic>{},
  };
  List<BookSource> get sources {
    _sync();
    return List.unmodifiable(
      (_data['sources'] as List).map(
        (s) => BookSource(Map<String, dynamic>.from(s)),
      ),
    );
  }

  BookSource? source(String id) {
    for (final item in sources) {
      if (item.id == id) return item;
    }
    return null;
  }

  BookSource? get active {
    _sync();
    final id = _data['active'];
    final found = id is String ? source(id) : null;
    return found?.enabled == true ? found : null;
  }

  Map<String, dynamic>? book(int id) {
    _sync();
    final value = (_data['books'] as Map)['$id'];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  void reload({bool notify = true}) {
    _encoded = preferences.getString(legadoStoreKey);
    _data = decodeRecord(_encoded);
    if (notify) notifyListeners();
  }

  Future<T> _change<T>(
    T Function(Map<String, dynamic>) change, {
    bool notify = false,
  }) {
    final pending = _writes.then((_) async {
      final raw = preferences.getString(legadoStoreKey);
      final next = raw != null && raw.length > 65536
          ? await compute(SourceStore.decodeRecord, raw)
          : decodeRecord(raw);
      final result = change(next);
      final encoded = raw != null && raw.length > 65536
          ? await compute(_encodeSourceRecord, next)
          : jsonEncode(next);
      if (utf8.encode(encoded).length > 3 * 1024 * 1024) {
        throw const FormatException('书源与书籍索引超过 3 MiB，请减少书源数量');
      }
      if (!await preferences.setString(legadoStoreKey, encoded)) {
        throw const FormatException('书源信息保存失败');
      }
      _data = next;
      _encoded = encoded;
      if (notify) notifyListeners();
      return result;
    });
    _writes = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  Future<int> importText(String text) async {
    final imported = text.length > 65536
        ? await compute(SourceStore.parseSources, text)
        : parseSources(text);
    return _change((next) {
      final merged = <String, dynamic>{
        for (final raw in next['sources'] as List)
          raw['bookSourceUrl'] as String: raw,
        for (final raw in imported) raw['bookSourceUrl'] as String: raw,
      };
      if (merged.length > 500) throw const FormatException('最多保存 500 个书源');
      next['sources'] = merged.values.toList();
      return imported.length;
    }, notify: true);
  }

  Future<void> select(String? id) => _change((next) {
    if (id != null && source(id)?.enabled != true) {
      throw const FormatException('书源不可用');
    }
    next['active'] = id;
  }, notify: true);
  Future<void> enable(String id, bool enabled) => _change((next) {
    for (final raw in next['sources'] as List) {
      if (raw['bookSourceUrl'] == id) raw['enabled'] = enabled;
    }
    if (!enabled && next['active'] == id) next['active'] = null;
  }, notify: true);
  Future<void> remove(String id) => _change((next) {
    (next['sources'] as List).removeWhere((s) => s['bookSourceUrl'] == id);
    if (next['active'] == id) next['active'] = null;
    // Keep book identities and cached reading records for re-import/resume.
  }, notify: true);
  Future<List<Map<String, dynamic>>> rememberBooks(
    BookSource source,
    List<Map<String, dynamic>> incoming,
  ) => _change((next) {
    final saved = next['books'] as Map;
    return incoming.map((raw) {
      final url = raw['url'];
      if (url is! String || !validSourceRequest(url)) {
        throw const FormatException('书源返回了无效的书籍地址');
      }
      final identity = '${source.id}\n$url';
      var id = sourceBookIdStart + _hash(identity, 0x1fffffff);
      while (saved['$id'] != null &&
          (saved['$id']['source'] != source.id || saved['$id']['url'] != url)) {
        id = sourceBookIdStart + ((id - sourceBookIdStart + 1) & 0x1fffffff);
      }
      final previous = saved['$id'] as Map?;
      final record = <String, dynamic>{
        ...?previous?.cast<String, dynamic>(),
        for (final entry in raw.entries)
          if (entry.value != null && entry.value != '') entry.key: entry.value,
        'id': id,
        'source': source.id,
        'chapterIds': previous?['chapterIds'] ?? <String, dynamic>{},
      };
      saved['$id'] = record;
      return Map<String, dynamic>.from(record);
    }).toList();
  });
  Future<List<Map<String, dynamic>>> rememberChapters(
    int id,
    List<Map<String, dynamic>> incoming,
  ) => _change((next) {
    final record = (next['books'] as Map)['$id'] as Map?;
    if (record == null) throw const FormatException('书籍索引不存在');
    final ids = record['chapterIds'] as Map;
    final used = ids.values.toSet();
    final seen = <String>{};
    final result = incoming.where((raw) => seen.add(raw['url'] as String)).map((
      raw,
    ) {
      final url = raw['url'] as String;
      if (!validSourceRequest(url)) throw const FormatException('章节地址无效');
      var chapterId = ids[url] as int?;
      if (chapterId == null) {
        chapterId = _hash(url, 0x3fffffff) + 1;
        while (used.contains(chapterId)) {
          chapterId = chapterId! % 0x40000000 + 1;
        }
        ids[url] = chapterId;
        used.add(chapterId);
      }
      return <String, dynamic>{...raw, 'id': chapterId};
    }).toList();
    record['chapterOrder'] = result.map((c) => c['url']).toList();
    return result;
  });
  String chapterUrl(int id, int chapterId) {
    final entries = (book(id)?['chapterIds'] as Map?)?.entries;
    return entries?.where((e) => e.value == chapterId).firstOrNull?.key
            as String? ??
        '';
  }

  static int _hash(String text, int mask) {
    final bytes = sha256.convert(utf8.encode(text)).bytes;
    return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
        mask;
  }

  static List<Map<String, dynamic>> parseSources(String text) {
    if (utf8.encode(text).length > 3 * 1024 * 1024) {
      throw const FormatException('书源 JSON 超过 3 MiB');
    }
    final value = jsonDecode(text.trim().replaceFirst('\uFEFF', ''));
    final list = value is List ? value : [value];
    if (list.isEmpty || list.length > 500) {
      throw const FormatException('书源数量须为 1～500');
    }
    final result = <Map<String, dynamic>>[];
    for (final item in list) {
      if (item is! Map<String, dynamic> ||
          item['bookSourceUrl'] is! String ||
          !validSourceUrl(item['bookSourceUrl']) ||
          item['bookSourceName'] is! String ||
          (item['bookSourceName'] as String).trim().isEmpty) {
        throw const FormatException('不是有效的阅读书源 JSON（缺少名称或网址）');
      }
      if (item['bookSourceType'] != null && item['bookSourceType'] != 0) {
        continue;
      }
      if (item['ruleSearch'] is! Map ||
          item['ruleToc'] is! Map ||
          item['ruleContent'] is! Map) {
        throw FormatException('「${item['bookSourceName']}」缺少搜索、目录或正文规则');
      }
      result.add(Map<String, dynamic>.from(item));
    }
    if (result.isEmpty) throw const FormatException('订阅中没有文字小说书源');
    return result;
  }

  static Map<String, dynamic> decodeRecord(String? text) {
    if (text == null) return emptyRecord();
    if (utf8.encode(text).length > 3 * 1024 * 1024) {
      throw const FormatException('书源索引过大');
    }
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['sources'] is! List ||
        value['books'] is! Map ||
        (value['active'] != null && value['active'] is! String)) {
      throw const FormatException('书源索引格式有误');
    }
    if ((value['sources'] as List).isNotEmpty) {
      parseSources(jsonEncode(value['sources']));
    }
    final identities = <String>{};
    for (final entry in (value['books'] as Map).entries) {
      final id = int.tryParse(entry.key.toString());
      final book = entry.value;
      if (id == null ||
          !isSourceBook(id) ||
          book is! Map ||
          book['id'] != id ||
          book['source'] is! String ||
          !validSourceUrl(book['source']) ||
          !validSourceRequest(book['url']) ||
          book['chapterIds'] is! Map ||
          !identities.add('${book['source']}\n${book['url']}')) {
        throw const FormatException('书源书籍索引格式有误');
      }
      final ids = <int>{};
      for (final chapter in (book['chapterIds'] as Map).entries) {
        if (!validSourceRequest(chapter.key) ||
            chapter.value is! int ||
            chapter.value <= 0 ||
            chapter.value > 0x40000000 ||
            !ids.add(chapter.value)) {
          throw const FormatException('章节身份映射格式有误');
        }
      }
    }
    return value;
  }

  /// Reject incompatible identity maps before any reading records are committed.
  static String mergeRecords(String? current, String incoming) {
    final next = decodeRecord(current), other = decodeRecord(incoming);
    final books = next['books'] as Map;
    for (final entry in (other['books'] as Map).entries) {
      final old = books[entry.key] as Map?;
      final book = entry.value as Map;
      if (old != null) {
        if (old['source'] != book['source'] || old['url'] != book['url']) {
          throw const FormatException('备份与本机的书源书籍 ID 冲突，未合并任何记录');
        }
        final chapters = {...old['chapterIds'] as Map};
        for (final chapter in (book['chapterIds'] as Map).entries) {
          if ((chapters.containsKey(chapter.key) &&
                  chapters[chapter.key] != chapter.value) ||
              chapters.entries.any(
                (e) => e.key != chapter.key && e.value == chapter.value,
              )) {
            throw const FormatException('备份与本机的章节 ID 冲突，未合并任何记录');
          }
          chapters[chapter.key] = chapter.value;
        }
        books[entry.key] = {...book, ...old, 'chapterIds': chapters};
      } else {
        books[entry.key] = book;
      }
    }
    final sources = <String, dynamic>{
      for (final raw in other['sources'] as List)
        raw['bookSourceUrl'] as String: raw,
      for (final raw in next['sources'] as List)
        raw['bookSourceUrl'] as String: raw,
    };
    next['sources'] = sources.values.toList();
    if (current == null) next['active'] = other['active'];
    final encoded = jsonEncode(next);
    decodeRecord(encoded);
    return encoded;
  }
}

bool validSourceUrl(Object? value) {
  if (value is! String || value.length > 8192) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      ['http', 'https'].contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

/// Request options are part of Legado book/chapter URLs and their identity.
bool validSourceRequest(Object? value) {
  if (value is! String || value.length > 32768) return false;
  final match = RegExp(r',\s*(?=\{)').firstMatch(value);
  if (match == null) return validSourceUrl(value);
  if (!validSourceUrl(value.substring(0, match.start))) return false;
  try {
    return jsonDecode(value.substring(match.end)) is Map;
  } on FormatException {
    return false;
  }
}

String _encodeSourceRecord(Map<String, dynamic> record) => jsonEncode(record);
