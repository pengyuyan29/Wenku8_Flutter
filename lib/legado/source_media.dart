import 'package:flutter/services.dart';
import '../book_identity.dart';
import 'source_repository.dart';
import 'source_store.dart';

/// Source identity survives in cached image markers. Wenku's allowlist remains intact.
abstract final class SourceMedia {
  static SourceStore? store;
  static const bridge = SourceBridge();
  static String reference(int book, String url) => Uri(
    scheme: 'wenku-source',
    host: '$book',
    queryParameters: {'url': url},
  ).toString();
  static bool valid(Uri uri) =>
      uri.scheme == 'wenku-source' &&
      isSourceBook(int.tryParse(uri.host) ?? 0) &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      uri.path.isEmpty &&
      !uri.hasFragment &&
      uri.queryParameters.length == 1 &&
      validSourceUrl(uri.queryParameters['url']);
  static Future<Uint8List> load(String reference) async {
    final uri = Uri.parse(reference);
    if (!valid(uri)) throw const FormatException('书源插图地址无效');
    return image(int.parse(uri.host), uri.queryParameters['url']!);
  }

  static Future<Uint8List> cover(int id) async {
    final address = store?.book(id)?['coverUrl'];
    if (address is! String || address.isEmpty) {
      throw const FormatException('书籍没有封面');
    }
    return image(id, address);
  }

  static Future<Uint8List> image(int id, String url) async {
    final book = store?.book(id);
    final source = book == null
        ? null
        : store?.source(book['source'] as String);
    if (source == null) throw const FormatException('请重新导入原书源以加载图片');
    return await bridge.call('image', {
          'source': source.json,
          'book': book,
          'url': url,
        })
        as Uint8List;
  }
}
