import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_interactions.dart';
import 'app_typography.dart';
import 'app_ui.dart';
import 'book_documents.dart';
import 'feature_pages.dart' show confirmNovelAction;
import 'library_state.dart';
import 'user_fonts.dart';

class FontSettingsPage extends StatefulWidget {
  const FontSettingsPage({
    super.key,
    required this.state,
    this.readerOnly = false,
    this.documents,
  });
  final LibraryState state;
  final bool readerOnly;
  final BookDocuments? documents;
  @override
  State<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<FontSettingsPage> {
  late final documents = widget.documents ?? BookDocuments();
  bool busy = false;
  String? error;
  Future<void> _choose({required bool reader}) async {
    final state = widget.state, fonts = widget.state.fonts;
    final selected = reader ? state.readerTypeface : state.appFontChoice;
    final value = await showJellySheet<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      heightFactor: .72,
      builder: (sheet) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          ArchiveSection(
            title: reader ? '阅读器字体' : 'App 字体',
            code: 'TYPE / SELECT',
          ),
          const SizedBox(height: 18),
          for (final id in [
            if (reader) followAppFont,
            ...AppTypeface.values.map((font) => font.name),
            ...fonts.fonts.map((font) => font.id),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _fontOption(
                id,
                reader: reader,
                selected: selected == id,
                onTap: () => Navigator.pop(sheet, id),
              ),
            ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    await _perform(
      () => reader ? state.setReaderTypeface(value) : state.setAppFont(value),
    );
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '字体操作未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _import() => _perform(() async {
    final selected = await documents.pickFont();
    if (selected == null) return;
    try {
      final font = await widget.state.fonts.importFile(
        selected.name,
        selected.path!,
      );
      if (mounted) {
        showNovelFeedback(context, '已导入 ${font.name}，可分别设为 App 或阅读器字体');
      }
    } finally {
      await documents.releaseBooks([selected]);
    }
  });
  Future<void> _delete(UserFont font) async {
    if (!await confirmNovelAction(
      context,
      title: '移除这款字体？',
      message: '已使用这款字体的位置会恢复默认，原始字体文件不会删除。',
      confirmLabel: '移除字体',
      reduceMotion: widget.state.reduceMotion,
    )) {
      return;
    }
    await _perform(() => widget.state.removeUserFont(font.id));
  }

  Widget _selection({required bool reader}) {
    final state = widget.state;
    final choice = reader ? state.readerTypeface : state.appFontChoice;
    return GlassTextButton(
      key: ValueKey(reader ? 'select-reader-font' : 'select-app-font'),
      onPressed: busy ? null : () => _choose(reader: reader),
      child: Row(
        children: [
          Icon(
            reader ? CupertinoIcons.book : CupertinoIcons.textformat,
            size: 21,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  reader ? '阅读器字体' : 'App 字体',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                AppText(
                  state.fontLabel(choice),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(CupertinoIcons.chevron_right, size: 14),
        ],
      ),
    );
  }

  Widget _fontOption(
    String id, {
    required bool reader,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final state = widget.state;
    final family =
        (id == followAppFont ? state.appFontFamily : state.fonts.family(id)) ??
        'Roboto';
    return _FontFacePreview(
      fonts: state.fonts,
      id: id == followAppFont ? state.appFontId : id,
      builder: (ready, failed) => GlassTextButton(
        key: ValueKey('${reader ? 'reader' : 'app'}-font-$id'),
        selected: selected,
        onPressed:
            busy ||
                !state.fonts.available(
                  id == followAppFont ? state.appFontId : id,
                )
            ? null
            : onTap,
        child: Row(
          children: [
            SizedBox(
              width: 38,
              child: AppText(
                'Aa',
                style: TextStyle(
                  fontFamily: ready ? family : null,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    state.fonts.label(id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  AppText(
                    !state.fonts.available(
                          id == followAppFont ? state.appFontId : id,
                        )
                        ? '未下载，可在字体页下载后选用'
                        : failed
                        ? '字体预览暂不可用'
                        : '春日的光，落在书页上。',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: ready ? family : null,
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 10),
              const Icon(CupertinoIcons.checkmark, size: 16),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _readerChoices() {
    final state = widget.state, fonts = state.fonts;
    return [
      const ArchiveSection(title: '阅读字体', code: 'TYPE / SELECT'),
      const SizedBox(height: 12),
      for (final id in [
        followAppFont,
        ...AppTypeface.values.map((f) => f.name),
        ...fonts.fonts.map((f) => f.id),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Semantics(
            inMutuallyExclusiveGroup: true,
            child: _fontOption(
              id,
              reader: true,
              selected: state.readerTypeface == id,
              onTap: () => _perform(() => state.setReaderTypeface(id)),
            ),
          ),
        ),
    ];
  }

  Future<void> _downloadOptional() => _perform(() async {
    final pack = widget.state.fonts.optionalFonts;
    final success = await pack.download();
    if (success) {
      await widget.state.loadFonts();
      if (mounted) showNovelFeedback(context, '思源宋体已下载，可分别设为 App 或阅读器字体');
    } else if (pack.error != null) {
      throw FormatException(pack.error!);
    }
  });
  Future<void> _removeOptional() async {
    if (!await confirmNovelAction(
      context,
      title: '删除已下载的思源宋体？',
      message: '使用它的位置会恢复系统字体，之后可以重新下载。',
      confirmLabel: '删除字体',
      reduceMotion: widget.state.reduceMotion,
    )) {
      return;
    }
    await _perform(() => widget.state.removeUserFont('sourceHanSerif'));
  }

  Widget _optionalFont() {
    final pack = widget.state.fonts.optionalFonts;
    final size = (pack.totalBytes / 1000000).toStringAsFixed(1);
    return ContentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ArchiveSection(title: '可选字体', code: 'TYPE / DOWNLOAD'),
          const SizedBox(height: 14),
          const AppText(
            '思源宋体',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          AppText(
            pack.ready
                ? '已下载 · 常规与粗体 · 可离线使用'
                : '默认使用系统字体。可下载思源宋体的常规与粗体，约 $size MB；也可以导入自己的字体。',
            style: const TextStyle(height: 1.7),
          ),
          if (pack.downloading) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(
              key: const ValueKey('font-download-progress'),
              value: pack.progress,
            ),
            const SizedBox(height: 8),
            AppText(
              '正在下载 ${(pack.received / 1000000).toStringAsFixed(1)} / $size MB',
            ),
            GlassTextButton(
              key: const ValueKey('cancel-font-download'),
              onPressed: pack.cancel,
              child: const AppText('取消下载'),
            ),
          ] else ...[
            if (pack.cancelled)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: AppText('下载已取消，可重新下载'),
              ),
            const SizedBox(height: 12),
            GlassTextButton(
              key: const ValueKey('download-source-han'),
              onPressed: busy
                  ? null
                  : pack.ready
                  ? _removeOptional
                  : _downloadOptional,
              child: AppText(
                pack.ready
                    ? '删除下载的字体'
                    : pack.error != null
                    ? '重新下载思源宋体'
                    : '下载思源宋体',
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.state.settingsChanges,
      widget.state.fonts,
      widget.state.fonts.optionalFonts,
    ]),
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
              title: '字体',
              code: 'TYPE / PERSONALIZE',
            ),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  MediaQuery.paddingOf(context).top +
                      FrostedHeader.toolbarHeight +
                      20,
                  24,
                  MediaQuery.paddingOf(context).bottom + 36,
                ),
                children: [
                  if (!widget.readerOnly) ...[
                    _selection(reader: false),
                    const SizedBox(height: 16),
                  ],
                  if (widget.readerOnly)
                    ..._readerChoices()
                  else
                    _selection(reader: true),
                  const SizedBox(height: 28),
                  _optionalFont(),
                  const SizedBox(height: 28),
                  const ArchiveSection(title: '我的字体', code: 'TTF / OTF'),
                  const SizedBox(height: 14),
                  GlassPillButton(
                    key: const ValueKey('import-font'),
                    icon: CupertinoIcons.plus,
                    label: busy ? '正在处理字体' : '导入字体',
                    onPressed: busy ? null : _import,
                  ),
                  const SizedBox(height: 12),
                  const AppText(
                    '支持 TTF、OTF，单款 32 MiB 以内。导入后可分别用于界面和阅读。',
                    style: TextStyle(height: 1.7),
                  ),
                  if ((error ?? widget.state.fontError) case final message?)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: AppText(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (widget.state.fontError != null)
                    GlassTextButton(
                      onPressed: busy
                          ? null
                          : () => _perform(widget.state.loadFonts),
                      child: const AppText('重试读取字体'),
                    ),
                  for (final font in widget.state.fonts.fonts)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: AppText(
                              font.name,
                              style: const TextStyle(height: 1.6),
                            ),
                          ),
                          const SizedBox(width: 12),
                          GlassIconButton(
                            icon: CupertinoIcons.trash,
                            label: '移除 ${font.name}',
                            onPressed: busy ? null : () => _delete(font),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// Load only mounted choices, and use the store's one-load-per-face cache. A
// library of large custom fonts must not all be decoded when opening settings.
class _FontFacePreview extends StatefulWidget {
  const _FontFacePreview({
    required this.fonts,
    required this.id,
    required this.builder,
  });
  final UserFontStore fonts;
  final String id;
  final Widget Function(bool ready, bool failed) builder;
  @override
  State<_FontFacePreview> createState() => _FontFacePreviewState();
}

class _FontFacePreviewState extends State<_FontFacePreview> {
  Future<void>? _loading;
  bool _available = false;
  @override
  void initState() {
    super.initState();
    _prepare();
  }

  void _prepare() {
    _available = widget.fonts.available(widget.id);
    _loading = !widget.fonts.available(widget.id) || widget.id == 'system'
        ? null
        : widget.fonts.ensureLoaded(widget.id);
  }

  @override
  void didUpdateWidget(_FontFacePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id ||
        oldWidget.fonts != widget.fonts ||
        _available != widget.fonts.available(widget.id)) {
      _prepare();
    }
  }

  @override
  Widget build(BuildContext context) => _loading == null
      ? widget.builder(widget.fonts.available(widget.id), false)
      : FutureBuilder<void>(
          future: _loading,
          builder: (context, snapshot) => widget.builder(
            snapshot.connectionState == ConnectionState.done &&
                !snapshot.hasError,
            snapshot.hasError,
          ),
        );
}
