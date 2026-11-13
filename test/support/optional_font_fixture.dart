import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/optional_fonts.dart';
import 'package:wenku8_flutter/user_fonts.dart';

/// Font binaries are development fixtures, absent from the application's bundle.
Future<ByteData> sourceHanFixture(String weight) => SynchronousFuture(
  ByteData.sublistView(
    File('assets/fonts/SourceHanSerifCN-$weight.otf').readAsBytesSync(),
  ),
);

Future<UserFontStore> cachedSourceHanFonts({
  Future<void> Function(String, File)? loader,
}) async {
  final root = await Directory.systemTemp.createTemp('optional-font-fixture-');
  addTearDown(() => root.delete(recursive: true));
  for (final file in sourceHanFiles) {
    await Link(
      '${root.path}/${file.name}',
    ).create(File('assets/fonts/${file.name}').absolute.path);
  }
  await File('${root.path}/ready.json').writeAsString(
    jsonEncode({
      'version': 1,
      'hashes': sourceHanFiles.map((f) => f.sha256sum).toList(),
    }),
  );
  final pack = OptionalFontPack(directory: root);
  final store = UserFontStore(
    directory: Directory('${root.path}/custom'),
    optionalFonts: pack,
    loader: loader ?? (_, _) async {},
  );
  await store.load();
  return store;
}
