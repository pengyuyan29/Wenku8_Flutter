import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_ui.dart';
import '../local_platform.dart';
import 'source_repository.dart';
import 'source_store.dart';

class SourceScope extends InheritedNotifier<SourceStore> {
  const SourceScope({
    super.key,
    required SourceStore store,
    required super.child,
  }) : super(notifier: store);
  static SourceStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SourceScope>()?.notifier;
}

class SourcePage extends StatefulWidget {
  const SourcePage({
    super.key,
    required this.store,
    this.bridge = const SourceBridge(),
  });
  final SourceStore store;
  final SourceBridge bridge;
  @override
  State<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<SourcePage> {
  final _input = TextEditingController(text: defaultSourceSubscription);
  final _query = TextEditingController();
  String? _busy, _error, _status;
  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _error = null;
      _status = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is FormatException ? e.message : '操作失败：$e');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _import(String? text) async {
    if (text == null) return;
    var value = text.trim();
    if (validSourceUrl(value)) value = await widget.bridge.fetch(value);
    final count = await widget.store.importText(value);
    if (mounted) setState(() => _status = '已导入 $count 个书源，重复网址已更新。请选择要使用的小说书源');
  }

  Future<void> _debug(
    BookSource source,
  ) => _run('正在测试「${source.name}」…', () async {
    final query = _query.text.trim();
    if (query.isEmpty) throw const FormatException('请先填写测试书名');
    final response =
        await widget.bridge.call('search', {
              'source': source.json,
              'query': query,
              'page': 1,
            })
            as Map;
    final items = response['items'] as List;
    if (items.isEmpty) throw const FormatException('搜索未返回书籍，请换关键词或检查搜索规则');
    final book = Map<String, dynamic>.from(items.first as Map);
    final detail = Map<String, dynamic>.from(
      await widget.bridge.call('detail', {'source': source.json, 'book': book})
          as Map,
    );
    final loaded = {
      ...book,
      for (final e in detail.entries)
        if (e.value != '') e.key: e.value,
    };
    final chapters =
        await widget.bridge.call('chapters', {
              'source': source.json,
              'book': loaded,
            })
            as List;
    if (chapters.isEmpty) throw const FormatException('目录为空');
    final body =
        await widget.bridge.call('content', {
              'source': source.json,
              'book': loaded,
              'chapter': chapters.first,
              if (chapters.length > 1)
                'nextChapterUrl': (chapters[1] as Map)['url'],
            })
            as String;
    if (mounted) {
      setState(
        () => _status =
            '「${source.name}」测试通过\n${loaded['title']} · ${chapters.length} 章\n首章 ${body.length} 字符\n${body.substring(0, body.length.clamp(0, 160))}',
      );
    }
  });
  @override
  void dispose() {
    _input.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: ArchiveHeaderBar(
            leading: GlassIconButton(
              icon: CupertinoIcons.back,
              label: '返回',
              onPressed: () => Navigator.pop(context),
            ),
            title: const ArchiveRouteTitle(
              title: '书源',
              code: 'LIBRARY / SOURCES',
            ),
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(
              24,
              MediaQuery.paddingOf(context).top +
                  FrostedHeader.toolbarHeight +
                  20,
              24,
              40,
            ),
            children: [
              const AppText(
                '你的阅读来源',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const AppText('导入阅读书源，选择后在发现页浏览和搜索。书架中的书始终使用各自原来的书源。'),
              const SizedBox(height: 20),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const ValueKey('source-input'),
                      controller: _input,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: '订阅网址或书源 JSON',
                        hintText: 'https://… 或 [{…}]',
                      ),
                    ),
                    const SizedBox(height: 12),
                    GlassTextButton(
                      key: const ValueKey('source-import'),
                      onPressed: _busy == null
                          ? () => _run('正在导入书源…', () => _import(_input.text))
                          : null,
                      child: const AppText('导入书源'),
                    ),
                    GlassTextButton(
                      onPressed: _busy == null
                          ? () => _run(
                              '正在读取剪贴板…',
                              () async => _import(
                                (await Clipboard.getData(
                                  Clipboard.kTextPlain,
                                ))?.text,
                              ),
                            )
                          : null,
                      child: const AppText('从剪贴板导入'),
                    ),
                    if (LocalPlatform.android)
                      GlassTextButton(
                        onPressed: _busy == null
                            ? () => _run(
                                '正在读取文件…',
                                () async =>
                                    _import(await LocalPlatform.importBackup()),
                              )
                            : null,
                        child: const AppText('选择 JSON 文件'),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('source-test-query'),
                      controller: _query,
                      decoration: const InputDecoration(
                        labelText: '测试书名',
                        hintText: '填写后点击书源旁的测试按钮',
                      ),
                    ),
                  ],
                ),
              ),
              if (_busy != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: AppText(_busy!),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: SelectableText(_status!),
                ),
              const SizedBox(height: 20),
              ContentPanel(
                onTap: _busy == null
                    ? () => _run('正在切换…', () => widget.store.select(null))
                    : null,
                child: Row(
                  children: [
                    Expanded(
                      child: AppText(
                        '轻小说文库',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (widget.store.active == null)
                      const Icon(CupertinoIcons.check_mark_circled_solid),
                  ],
                ),
              ),
              for (final source in widget.store.sources)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: AppText(
                                source.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (widget.store.active?.id == source.id)
                              const Icon(
                                CupertinoIcons.check_mark_circled_solid,
                              ),
                            Switch(
                              value: source.enabled,
                              onChanged: _busy == null
                                  ? (value) => _run(
                                      '正在保存…',
                                      () =>
                                          widget.store.enable(source.id, value),
                                    )
                                  : null,
                            ),
                          ],
                        ),
                        AppText(source.id, maxLines: 2),
                        Wrap(
                          spacing: 12,
                          children: [
                            GlassTextButton(
                              onPressed: _busy == null && source.enabled
                                  ? () => _run(
                                      '正在切换…',
                                      () => widget.store.select(source.id),
                                    )
                                  : null,
                              child: const AppText('使用此源'),
                            ),
                            GlassTextButton(
                              onPressed: _busy == null
                                  ? () => _debug(source)
                                  : null,
                              child: const AppText('测试'),
                            ),
                            GlassTextButton(
                              onPressed: _busy == null
                                  ? () => _run(
                                      '正在移除…',
                                      () => widget.store.remove(source.id),
                                    )
                                  : null,
                              child: const AppText('移除'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
