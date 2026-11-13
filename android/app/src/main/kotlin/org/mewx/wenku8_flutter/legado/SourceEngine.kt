package org.mewx.wenku8_flutter.legado

import org.json.JSONObject
import org.json.JSONArray
import org.jsoup.Jsoup
import org.jsoup.nodes.TextNode
import org.jsoup.nodes.Element
import java.net.URI

/** Each operation has its own rule context; only a source's HTTP cookie jar is shared. */
class SourceEngine(private val http: SourceHttp = SourceHttp(), private val chinese: SourceChinese? = null) {
    fun run(method: String, args: Map<String, Any?>): Any {
        val source = JSONObject(args["source"] as? Map<*, *> ?: emptyMap<Any, Any>())
        val root = source.optString("bookSourceUrl")
        val headers = mutableMapOf<String, String>()
        val rules = RuleEvaluator(http, headers, chinese).apply { baseUrl = root }
        val header = source.optString("header")
        if (header.isNotBlank()) {
            val parsed = JSONObject(if (header.startsWith("@js:")) rules.eval(header.substring(4)) else header)
            parsed.keys().forEach { headers[it] = parsed.getString(it) }
        }
        rules.bindings["source"] = args["source"] as? Map<*, *> ?: emptyMap<Any, Any>()
        rules.bindings["key"] = args["query"] ?: ""
        rules.bindings["page"] = (args["page"] as? Number)?.toInt() ?: 1
        val book = args["book"] as? Map<*, *> ?: emptyMap<Any, Any>()
        rules.bindings["book"] = book + mapOf("name" to (book["title"] ?: ""), "bookUrl" to (book["url"] ?: ""), "origin" to root)
        rules.bindings["chapter"] = args["chapter"] as? Map<*, *> ?: emptyMap<Any, Any>()
        val lib = source.optString("jsLib")
        if (lib.isNotBlank()) rules.eval(if (lib.trim().startsWith("http")) http.request(lib, root, headers).body else lib)
        fun ruleSet(name: String): JSONObject = source.optJSONObject(name) ?: error("书源缺少 $name")
        fun load(url: String): SourceHttp.Response {
            val response = http.request(url, rules.baseUrl, headers)
            rules.baseUrl = response.url; rules.content = response.body
            return response
        }
        fun absolute(value: String): String = absoluteRequest(value, rules.baseUrl)
        fun field(set: JSONObject, key: String, input: Any = rules.content): String = rules.text(set.optString(key), input)
        fun parseBook(set: JSONObject, input: Any): Map<String, Any> {
            val url = absolute(field(set, "bookUrl", input)).ifEmpty { rules.baseUrl }
            return mapOf(
                "url" to url, "title" to field(set, "name", input), "author" to field(set, "author", input),
                "genre" to field(set, "kind", input), "summary" to field(set, "intro", input),
                "coverUrl" to absolute(field(set, "coverUrl", input)), "lastUpdate" to field(set, "lastChapter", input),
                "tocUrl" to absolute(field(set, "tocUrl", input)),
            )
        }
        return when (method) {
            "image" -> {
                val url = args["url"]?.toString() ?: error("缺少图片地址")
                val imageHeaders = headers.toMutableMap()
                imageHeaders.putIfAbsent("Referer", book["url"]?.toString() ?: root)
                http.request(url, root, imageHeaders).bytes
            }
            "search", "browse" -> {
                val search = method == "search"
                val set = ruleSet(if (search) "ruleSearch" else "ruleExplore")
                var template = if (search) source.optString("searchUrl") else source.optString("exploreUrl")
                if (!search) {
                    require(!template.startsWith("<js>") && !template.startsWith("@js:")) { "动态发现列表尚未支持，请使用搜索" }
                    template = if (template.trim().startsWith("[")) {
                        JSONArray(template).optJSONObject(0)?.optString("url").orEmpty()
                    } else template.lineSequence().firstOrNull { it.contains("::") }?.substringAfter("::") ?: template
                }
                require(template.isNotBlank()) { if (search) "书源未配置搜索" else "这个书源没有发现列表，请使用搜索" }
                load(url(template, rules))
                val books = rules.values(set.optString("bookList")).map { parseBook(set, it) }
                    .filter { it["title"].toString().isNotBlank() }.distinctBy { it["url"] }
                mapOf("items" to books)
            }
            "detail" -> {
                load(book["url"]?.toString() ?: error("缺少书籍地址"))
                val set = ruleSet("ruleBookInfo")
                val init = set.optString("init")
                if (init.isNotBlank()) rules.content = rules.values(init).firstOrNull() ?: rules.content
                parseBook(set, rules.content).toMutableMap().apply { put("url", book["url"].toString()) }
            }
            "chapters" -> {
                load(book["tocUrl"]?.toString()?.ifBlank { null } ?: book["url"]?.toString() ?: error("缺少目录地址"))
                val set = ruleSet("ruleToc")
                var listRule = set.optString("chapterList")
                val reverse = listRule.startsWith("-")
                if (reverse) listRule = listRule.substring(1)
                val chapters = mutableListOf<Map<String, Any>>()
                val visited = mutableSetOf<String>()
                val pending = java.util.ArrayDeque<String>()
                var volume = ""
                while (visited.add(rules.baseUrl)) {
                    check(visited.size <= 100) { "目录分页超过 100 页" }
                    rules.values(listRule).forEach { item ->
                        val title = field(set, "chapterName", item)
                        val volumeFlag = field(set, "isVolume", item)
                        if (volumeFlag.isNotBlank() && volumeFlag !in setOf("false", "0")) volume = title
                        else {
                            val address = absolute(field(set, "chapterUrl", item))
                            if (title.isNotBlank() && address.isNotBlank()) chapters.add(mapOf("title" to title, "url" to address, "volumeTitle" to volume))
                        }
                    }
                    rules.values(set.optString("nextTocUrl")).flatMap { rules.stringify(it).lines() }
                        .filter { it.isNotBlank() }.map(::absolute).filter { it !in visited && it !in pending }.forEach { pending.add(it) }
                    while (pending.isNotEmpty() && pending.first() in visited) pending.removeFirst()
                    if (pending.isEmpty()) break
                    load(pending.removeFirst())
                }
                val unique = chapters.distinctBy { it["url"] }
                check(unique.isNotEmpty()) { "目录规则没有提取到章节" }
                if (reverse) unique.reversed() else unique
            }
            "content" -> {
                val chapter = args["chapter"] as? Map<*, *> ?: error("缺少章节")
                load(chapter["url"]?.toString() ?: error("缺少章节地址"))
                val set = ruleSet("ruleContent")
                val pages = mutableListOf<String>(); val visited = mutableSetOf<String>()
                val pending = java.util.ArrayDeque<String>()
                while (visited.add(rules.baseUrl)) {
                    check(visited.size <= 50) { "正文分页超过 50 页" }
                    var body = field(set, "content")
                    val replace = set.optString("replaceRegex")
                    if (replace.isNotBlank()) {
                        val original = rules.content
                        try { rules.content = body; body = rules.text("@js:result" + (if (replace.startsWith("##")) replace else "##$replace")) } finally { rules.content = original }
                    }
                    pages.add(formatBody(body, rules.baseUrl))
                    rules.values(set.optString("nextContentUrl")).flatMap { rules.stringify(it).lines() }
                        .filter { it.isNotBlank() }.map(::absolute)
                        .filter { it !in visited && it !in pending && it != args["nextChapterUrl"] }.forEach { pending.add(it) }
                    while (pending.isNotEmpty() && pending.first() in visited) pending.removeFirst()
                    if (pending.isEmpty()) break
                    load(pending.removeFirst())
                }
                pages.joinToString("\n\n").trim().also { check(it.isNotBlank()) { "正文规则提取为空" } }
            }
            else -> error("未知书源操作")
        }
    }
    fun url(template: String, rules: RuleEvaluator): String {
        if (template.startsWith("@js:") || template.startsWith("<js>")) return rules.eval(template.removePrefix("@js:").removePrefix("<js>").removeSuffix("</js>"))
        val charset = Regex("[\"']charset[\"']\\s*:\\s*[\"']([^\"']+)").find(template)?.groupValues?.get(1) ?: "UTF-8"
        var value = Regex("\\{\\{(.*?)\\}\\}", RegexOption.DOT_MATCHES_ALL).replace(template) {
            when (it.groupValues[1].trim()) {
                "key", "searchKey" -> SourceHttp.encode(rules.bindings["key"].toString(), charset)
                "page" -> rules.bindings["page"].toString()
                else -> rules.eval(it.groupValues[1])
            }
        }
        val page = rules.bindings["page"] as Int
        value = Regex("<([^<>]+,[^<>]+)>").replace(value) { val choices = it.groupValues[1].split(','); choices[(page - 1).coerceIn(0, choices.lastIndex)] }
        return value.replace("<page>", page.toString()).replace("<searchKey>", SourceHttp.encode(rules.bindings["key"].toString(), charset))
    }
    companion object {
        fun absoluteRequest(value: String, base: String): String {
            if (value.isBlank()) return ""
            val split = Regex(",\\s*(?=\\{)").find(value)
            val address = if (split == null) value else value.substring(0, split.range.first)
            val suffix = if (split == null) "" else value.substring(split.range.first)
            return URI(base.substringBefore(",{")).resolve(address.trim().replace(" ", "%20")).toString() + suffix
        }

        fun formatBody(markup: String, base: String): String {
            if (!Regex("</?[a-zA-Z][^>]*>").containsMatchIn(markup)) return markup.replace("\r", "").trim().split(Regex("\n[ \\t]*\n|\n")).filter { it.isNotBlank() }.joinToString("\n\n") { it.trim() }
            val doc = Jsoup.parseBodyFragment(markup, base)
            doc.select("script,style,noscript").remove()
            doc.select("img").forEach { image ->
                val raw = listOf("data-src", "data-original", "src").map { image.attr(it) }.firstOrNull { it.isNotBlank() }.orEmpty()
                val address = runCatching { URI(base).resolve(raw).toString() }.getOrDefault("")
                image.replaceWith(TextNode("\n\n<!--image-->$address<!--image-->\n\n"))
            }
            doc.select("br").forEach { it.replaceWith(TextNode("\n\n")) }
            doc.select("p,div,li,h1,h2,h3,section").forEach { it.appendChild(TextNode("\n\n")) }
            return doc.body().wholeText().replace("\r", "").split(Regex("\n+")).map { it.trim() }.filter { it.isNotBlank() }.joinToString("\n\n")
        }
    }
}
