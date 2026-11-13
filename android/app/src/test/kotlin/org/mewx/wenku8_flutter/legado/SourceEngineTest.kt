package org.mewx.wenku8_flutter.legado

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.json.JSONObject

class SourceEngineTest {
    private lateinit var server: HttpServer
    private lateinit var root: String
    private val lastPost = AtomicReference("")
    @Before fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        root = "http://127.0.0.1:${server.address.port}"
        server.createContext("/") { exchange ->
            val path = exchange.requestURI.path
            val body = when (path) {
                "/search" -> {
                    exchange.responseHeaders.add("Set-Cookie", "reader=fixture; Path=/")
                    "<div class='book'><a href='/book'>测试小说</a><span>作者甲</span></div>"
                }
                "/book" -> {
                    check(exchange.requestHeaders.getFirst("Cookie").orEmpty().contains("reader=fixture"))
                    "<h1>测试小说</h1><p class='intro'>故事简介</p><a id='toc' href='/toc'>目录</a>"
                }
                "/toc" -> "<a class='chapter' href='/c1'>第一章</a><a class='next' href='/toc2'>下一页</a>"
                "/toc2" -> "<a class='chapter' href='/c2'>第二章</a><a class='next' href='/toc'>循环</a>"
                "/c1" -> "<article><p>第一段</p><img src='/image.jpg'><p>第二段</p></article><a class='next' href='/c1b'>下一页</a>"
                "/c1b" -> "<article><p>第三段</p></article><a class='next' href='/c2'>下一章</a>"
                "/json" -> """{"items":[{"name":"JSON小说","author":"乙","url":"/book"}]}"""
                "/ajax" -> "AJAX成功"
                "/post" -> { lastPost.set(exchange.requestBody.readAllBytes().toString(Charsets.UTF_8)); "<h1>提交成功</h1>" }
                "/gbk" -> "中文编码"
                else -> "OK"
            }
            val bytes = body.toByteArray(if (path == "/gbk") charset("GBK") else Charsets.UTF_8)
            exchange.responseHeaders.set("Content-Type", if (path == "/gbk") "text/html; charset=gbk" else "text/html; charset=utf-8")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
    }
    @After fun stop() { server.stop(0) }
    private fun source(): Map<String, Any> = mapOf(
        "bookSourceUrl" to root, "bookSourceName" to "fixture", "searchUrl" to "/search?q={{key}}&p={{page}}",
        "ruleSearch" to mapOf("bookList" to "class.book", "name" to "tag.a@text", "bookUrl" to "tag.a@href", "author" to "tag.span@text"),
        "ruleBookInfo" to mapOf("name" to "tag.h1@text", "intro" to "class.intro@text", "tocUrl" to "id.toc@href"),
        "ruleToc" to mapOf("chapterList" to "class.chapter", "chapterName" to "text", "chapterUrl" to "href", "nextTocUrl" to "class.next@href"),
        "ruleContent" to mapOf("content" to "tag.article@html", "nextContentUrl" to "class.next@href")
    )
    @Test fun htmlSourceReadsAllStagesWithCookiesPaginationAndImages() {
        val engine = SourceEngine()
        val source = source()
        val search = engine.run("search", mapOf("source" to source, "query" to "小说", "page" to 1)) as Map<*, *>
        val book = (search["items"] as List<*>).single() as Map<*, *>
        assertEquals("测试小说", book["title"])
        assertEquals("作者甲", book["author"])
        val detail = engine.run("detail", mapOf("source" to source, "book" to book)) as Map<*, *>
        assertEquals("故事简介", detail["summary"])
        val chapters = engine.run("chapters", mapOf("source" to source, "book" to detail)) as List<*>
        assertEquals(2, chapters.size)
        val body = engine.run("content", mapOf("source" to source, "book" to detail, "chapter" to chapters[0], "nextChapterUrl" to "$root/c2")) as String
        assertTrue(body.contains("第一段\n\n<!--image-->$root/image.jpg<!--image-->\n\n第二段"))
        assertTrue(body.endsWith("第三段"))
    }
    @Test fun jsonSourceUsesFilterPaths() {
        val source = source().toMutableMap().apply {
            put("searchUrl", "/json")
            put("ruleSearch", mapOf("bookList" to "$.items[?(@.author == '乙')]", "name" to "$.name", "author" to "$.author", "bookUrl" to "$.url"))
        }
        val result = SourceEngine().run("search", mapOf("source" to source)) as Map<*, *>
        assertEquals("JSON小说", ((result["items"] as List<*>).single() as Map<*, *>)["title"])
    }
    @Test fun xpathAndRegexCompositionAndVariables() {
        val rules = RuleEvaluator(SourceHttp()).apply { baseUrl = root; content = "<div><a href='/a'>甲1</a><a href='/b'>乙2</a></div>" }
        assertEquals("/a\n/b", rules.text("@XPath://a/@href"))
        assertEquals("甲\n乙", rules.text("tag.a@text##[0-9]##"))
        assertEquals("甲1\n乙2", rules.text("class.missing@text||tag.a@text"))
        assertEquals("甲1", rules.text("@put:{\"title\":\"tag.a.0@text\"}@js:java.get('title')"))
    }
    @Test fun javaAjaxIsSynchronousAndScopePersistsAcrossRules() {
        val rules = RuleEvaluator(SourceHttp()).apply { baseUrl = root }
        assertEquals("AJAX成功", rules.eval("java.ajax(baseUrl + '/ajax')"))
        assertEquals("4", rules.eval("var customValue = 2; customValue * 2"))
        assertEquals("3", rules.eval("customValue + 1"))
        assertEquals("e10adc3949ba59abbe56e057f20f883e", rules.eval("java.md5Encode('123456')"))
    }
    @Test fun postBodyAndGbkAreDecoded() {
        val http = SourceHttp()
        val response = http.request("/post,{\"method\":\"POST\",\"body\":\"q=hello\"}", root)
        assertEquals("q=hello", lastPost.get())
        assertTrue(response.body.contains("提交成功"))
        assertEquals("中文编码", http.request("/gbk", root).body)
    }
    @Test fun urlsUseJsPaginationAndEncodeSearchKeys() {
        val rules = RuleEvaluator(SourceHttp()).apply { bindings["key"] = "中文"; bindings["page"] = 3 }
        assertEquals("/search?q=%E4%B8%AD%E6%96%87&offset=40", SourceEngine().url("/search?q={{key}}&offset={{(page-1)*20}}", rules))
    }
    @Test fun jsStagesContinueIntoSelectorsAndIndicesExcludeHeaders() {
        val rules = RuleEvaluator(SourceHttp()).apply { baseUrl = root; content = "<div class='list'><p>表头</p><p><a href='/one'>章节一</a></p><p><a href='/two'>章节二</a></p></div>" }
        assertEquals("章节一\n章节二", rules.text("<js>result</js>\nclass.list@p!0@a@text"))
        assertEquals(2, rules.values("class.list@p!0@a").size)
        assertEquals("/two", rules.text("class.list@p.-1@a@href"))
    }
    @Test fun jsonTemplatesAndHostExtractionUseTheCurrentRow() {
        val rules = RuleEvaluator(SourceHttp()).apply { baseUrl = root; content = "{\"items\":[{\"id\":12},{\"id\":34}]}" }
        val rows = rules.values("$.items[*]")
        assertEquals(listOf("/book/12", "/book/34"), rows.map { rules.text("/book/{\$.id}", it) })
        assertEquals("id=34", rules.text("@js:'id=' + java.getString('$.id')", rows.last()))
        assertEquals("book/12", rules.text("@js:'book/{{$.id}}'", rows.first()))
    }
    @Test fun requestOptionsSurviveAbsoluteUrlResolution() {
        val request = SourceEngine.absoluteRequest("/toc,{\"method\":\"POST\",\"body\":\"id=12\"}", root)
        assertEquals("$root/toc,{\"method\":\"POST\",\"body\":\"id=12\"}", request)
    }
    @Test fun webViewSourcesFailWithActionableMessage() {
        try { SourceHttp().request("/ajax,{\"webView\":true}", root); fail("Expected unsupported WebView") }
        catch (e: IllegalArgumentException) { assertTrue(e.message.orEmpty().contains("WebView")) }
    }
}
