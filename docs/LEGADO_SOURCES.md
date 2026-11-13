# 自用分支：阅读书源与原有阅读界面

此分支保留文库的玻璃界面、书架、排版、听书和本地导入，新增 Android 阅读（Legado）文字小说书源。首次启动使用普通网络小说源「米读看书」，另附「梧桐中文」和「逐浪小说」。三者来自用户提供的订阅，已验证搜索、详情、目录和正文；不内置完整订阅，也不默认使用轻小说源。

## 使用

- 发现页右上角或「我的 → 书源」打开管理页。当前附带的源没有发现规则，直接点击搜索输入书名。
- 支持订阅 URL、单个 JSON、JSON 数组、剪贴板和 JSON 文件。用户提供的订阅 URL 已预填；若服务不可用，可导入下载的文件。
- 导入后显式选择「使用此源」。按来源网址更新重复条目；视频/音频等非文字类型跳过。最多 500 个条目、JSON 3 MiB。
- 「测试书名」配合每个源的「测试」按钮，依次检查搜索、详情、目录和首章，直接显示失败原因。
- 书架里的每本书固定使用自己的原书源，切换当前搜索源不会把已有书籍重定向到另一网站。暂不自动合并同名书或跨源换源。
- 阅读与下载沿用现有离线正文缓存。图片按来源使用独立的请求头、Cookie 和磁盘缓存，图片磁盘缓存上限 64 MiB，可能被系统清理。
- 常规「备份与恢复」包含书源、书籍/章节身份映射和阅读记录，不含 Cookie 或离线正文。恢复时遇到冲突会在提交阅读记录前报错。

## 支持范围

原生后台线程使用 Rhino 1.7.15、Jsoup 和 Jayway JSONPath；XPath 使用 JAXP。没有修改文库的私有 API 运行库。

已实现常用 CSS/JSoup 规则、负数及排除索引、XPath、JSONPath 过滤、正则替换、`||`/`&&`/`%%`、`@get`/`@put`、`@js:`、`<js>` 阶段、字段插值、搜索分页、GET/POST/请求选项、编码、Cookie、目录/正文分页和插图转换。常用 JS 桥包括同步 `java.ajax/connect`、规则取值、Base64、MD5、URL 编解码和繁简字符转换。

这不是完整 Legado 引擎。需要 WebView、验证码交互、字体反爬、复杂登录和未实现 `java.*` 扩展的源可能失败；动态发现分类暂未实现。完整订阅中有大量此类脚本，导入成功不代表全部书源都通过测试。脚本与站点规则变化也会影响可用性。

自定义书籍保留 `0x40000000..0x5fffffff` 的独立整数区间，本地书仍从 `0x60000000` 开始。映射持久化并检查哈希碰撞；自定义书籍不会进入文库云书架。章节按 URL 分配稳定 ID，目录重排不重用已有章节身份。

## 验证

```sh
flutter pub get
flutter analyze
flutter test test/legado_sources_test.dart test/offline_repository_test.dart \
  test/feature_unification_state_test.dart test/feature_completion_state_test.dart \
  test/listening_controller_test.dart test/navigation_modes_test.dart

# 无需 Android SDK 的实际规则引擎测试（Gradle 8.14、JDK 17+）
gradle -p tools/legado-engine-tests test

# 仅在本机读取订阅的可选联网检查；不上传或写入应用配置
# sourceIndex 为 JSON 数组中的下标，query 为测试书名
gradle -p tools/legado-engine-tests smoke \
  -PsourceFile=/absolute/path/sources.json -PsourceIndex=12 -Pquery=斗破

flutter build apk --debug --target-platform android-arm64
```

测试覆盖本地 HTTP 服务上的 Cookie、POST、GBK、CSS/XPath/JSON/JS、两类分页、图片标记，以及 Flutter 侧 ID 碰撞、目录重排、源切换时的过期结果、重启后的离线阅读、备份冲突和导入界面。可用 `LEGADO_SOURCE_FILE` 指定用户订阅运行额外导入/备份大小测试；测试不会把订阅复制进仓库。
