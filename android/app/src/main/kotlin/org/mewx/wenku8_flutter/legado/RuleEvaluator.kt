package org.mewx.wenku8_flutter.legado

import com.jayway.jsonpath.JsonPath
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.helper.W3CDom
import org.mozilla.javascript.Context
import org.mozilla.javascript.ContextFactory
import org.mozilla.javascript.NativeArray
import org.mozilla.javascript.NativeObject
import org.mozilla.javascript.Wrapper
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import org.mozilla.javascript.Undefined
import javax.xml.xpath.XPathConstants
import javax.xml.xpath.XPathFactory
import org.w3c.dom.NodeList

/** Legado's common rule grammar. Unsupported rules fail visibly, not as empty books. */
class RuleEvaluator(val http: SourceHttp, val headers: Map<String, String> = emptyMap(), val chinese: SourceChinese? = null) {
    var content: Any = ""
    var baseUrl = ""
    val variables = mutableMapOf<String, String>()
    val bindings = mutableMapOf<String, Any>("key" to "", "page" to 1)
    private var scope: Scriptable? = null
    private val factory = object : ContextFactory() {
        override fun makeContext(): Context = super.makeContext().apply {
            optimizationLevel = -1
            languageVersion = Context.VERSION_ES6
            instructionObserverThreshold = 10000
        }
        override fun observeInstructionCount(cx: Context, count: Int) {
            if (Thread.currentThread().isInterrupted || System.nanoTime() > deadline) error("书源脚本执行超时")
        }
    }
    private var deadline = Long.MAX_VALUE
    fun eval(script: String, result: Any = content): String = js(script, result)?.let(::stringify).orEmpty()
    fun js(script: String, result: Any = content): Any? {
        deadline = System.nanoTime() + 10_000_000_000L
        return factory.call<Any?> { cx ->
            val current = scope ?: cx.initStandardObjects().also { scope = it }
            ScriptableObject.putProperty(current, "java", Context.javaToJS(JavaBridge(this), current))
            ScriptableObject.putProperty(current, "baseUrl", baseUrl)
            ScriptableObject.putProperty(current, "result", toJs(cx, current, result))
            ScriptableObject.putProperty(current, "src", stringify(content))
            bindings.forEach { (key, value) -> ScriptableObject.putProperty(current, key, toJs(cx, current, value)) }
            val value = cx.evaluateString(current, script, "book-source", 1, null)
            fromJs(value)
        }
    }
    private fun fromJs(value: Any?): Any? = when (value) {
        null, is Undefined -> null
        is Wrapper -> fromJs(value.unwrap())
        is NativeArray -> (0 until value.length.toInt()).map { fromJs(value.get(it, value)) }
        is NativeObject -> value.ids.associate { id -> id.toString() to fromJs(value.get(id.toString(), value)) }
        else -> value
    }
    private fun toJs(cx: Context, scope: Scriptable, value: Any): Any = when (value) {
        is Map<*, *> -> cx.evaluateString(scope, "(${JSONObject(value).toString()})", "binding", 1, null)
        is Element -> value.outerHtml()
        else -> Context.javaToJS(value, scope)
    }
    fun stringify(value: Any?): String = when (value) {
        null, JSONObject.NULL, is Undefined -> ""
        is Element -> value.outerHtml()
        is Number -> Context.toString(value)
        is Map<*, *> -> JSONObject(value).toString()
        is List<*> -> value.joinToString("\n") { stringify(it) }
        is Scriptable -> Context.toString(value)
        else -> value.toString()
    }
    fun text(rule: String, input: Any = content): String = values(rule, input).joinToString("\n") { stringify(it) }.trim()
    fun values(rawRule: String, input: Any = content): List<Any> {
        val previous = content
        content = input
        return try { analyze(rawRule, input) } finally { content = previous }
    }
    private fun expand(text: String, input: Any): String = Regex("\\{\\{(.*?)\\}\\}", RegexOption.DOT_MATCHES_ALL).replace(text) {
        val expr = it.groupValues[1].trim()
        if (expr.startsWith("@") || expr.startsWith("$.") || expr.startsWith("$[") || expr.startsWith("//")) text(expr, input) else eval(expr, input)
    }
    private fun analyze(rawRule: String, input: Any): List<Any> {
        if (rawRule.isBlank()) return emptyList()
        var rule = rawRule.trim()
        if (rule.startsWith("@put:")) {
            val start = rule.indexOf('{'); val end = matchingBrace(rule, start)
            val vars = JSONObject(rule.substring(start, end + 1))
            vars.keys().forEach { variables[it] = text(vars.getString(it), input) }
            rule = rule.substring(end + 1)
        }
        if (rule.matches(Regex("@get:\\{[^}]+\\}"))) return listOf(variables[rule.substring(6, rule.length - 1)].orEmpty())
        // A <js> block is one stage; following CSS/JSON rules operate on its result.
        val block = rule.indexOf("<js>", ignoreCase = true)
        if (block >= 0) {
            val end = rule.indexOf("</js>", block, ignoreCase = true)
            require(end >= 0) { "书源 <js> 块未闭合" }
            val prefix = rule.substring(0, block).trim()
            val previous = if (prefix.isEmpty()) input else text(prefix, input)
            val evaluated = js(expand(rule.substring(block + 4, end), input), previous) ?: ""
            val tail = rule.substring(end + 5).trim()
            return if (tail.isNotBlank()) values(tail, evaluated) else if (evaluated is List<*>) evaluated.filterNotNull() else listOf(evaluated)
        }
        val inlineJs = rule.indexOf("@js:", ignoreCase = true)
        if (inlineJs >= 0) {
            val parts = split(rule, "##")
            val expression = parts.first()
            val prefix = expression.substring(0, inlineJs).trim()
            val previous = if (prefix.isEmpty()) input else text(prefix, input)
            val evaluated = js(expand(expression.substring(inlineJs + 4), input), previous)
            val result = if (evaluated is List<*>) evaluated.filterNotNull() else listOfNotNull(evaluated)
            return replace(result, parts, input)
        }
        val hadTemplate = rule.contains("{{") || Regex("\\{\\$[^}]+\\}").containsMatchIn(rule)
        rule = Regex("@get:\\{([^}]+)\\}").replace(rule) { variables[it.groupValues[1]].orEmpty() }
        rule = Regex("\\{\\{(.*?)\\}\\}", RegexOption.DOT_MATCHES_ALL).replace(rule) {
            val expr = it.groupValues[1].trim()
            if (expr.startsWith("@") || expr.startsWith("$.") || expr.startsWith("$[") || expr.startsWith("//")) text(expr, input) else eval(expr, input)
        }
        rule = Regex("\\{(\\$[^}]+)\\}").replace(rule) { text(it.groupValues[1], input) }
        if (rule.startsWith("http://") || rule.startsWith("https://") || hadTemplate) {
            val parts = split(rule, "##"); return replace(listOf(parts.first()), parts, input)
        }
        val fallback = split(rule, "||")
        if (fallback.size > 1) {
            for (candidate in fallback) { val found = values(candidate, input); if (found.any { stringify(it).isNotBlank() }) return found }
            return emptyList()
        }
        val concat = split(rule, "&&")
        if (concat.size > 1) return concat.flatMap { values(it, input) }
        val zip = split(rule, "%%")
        if (zip.size > 1) {
            val lists = zip.map { values(it, input) }
            return (0 until lists.maxOf { it.size }).flatMap { i -> lists.mapNotNull { it.getOrNull(i) } }
        }
        val replacements = split(rule, "##")
        rule = replacements.first()
        var result = when {
            rule.startsWith(":") -> regex(rule.substring(1), input)
            rule.startsWith("@Json:", true) || rule.startsWith("$.") || rule.startsWith("$[") -> json(rule.removePrefixIgnoreCase("@Json:"), input)
            rule.startsWith("@XPath:", true) || rule.startsWith("/") -> xpath(rule.removePrefixIgnoreCase("@XPath:"), input)
            rule.startsWith("@css:", true) -> css(rule.substring(5), input, true)
            input is Map<*, *> || input is List<*> || (input is String && (input.trim().startsWith("{") || input.trim().startsWith("["))) -> json(if (rule.startsWith("$")) rule else "$." + rule, input)
            else -> css(rule.removePrefix("@@"), input, false)
        }
        return replace(result, replacements, input)
    }
    private fun replace(result: List<Any>, parts: List<String>, input: Any): List<Any> {
        if (parts.size < 2 || parts[1].isEmpty()) return result
        val regex = Regex(parts[1])
        val replacement = parts.getOrElse(2) { "" }
        return result.map {
            if (parts.size > 3) regex.replaceFirst(stringify(it), replacement) else regex.replace(stringify(it), replacement)
        }
    }
    private fun css(rule: String, input: Any, standard: Boolean): List<Any> {
        if (rule.isBlank()) return listOf(input)
        var nodes: List<Any> = listOf(if (input is Element) input else Jsoup.parse(stringify(input), baseUrl))
        val segments = split(rule, "@")
        for ((index, segment) in segments.withIndex()) {
            if (segment.isEmpty()) continue
            val attribute = index == segments.lastIndex && (segment in setOf("text", "textNodes", "ownText", "html", "all", "href", "src", "content", "title", "alt", "value", "onclick", "style") || segment.startsWith("data-"))
            nodes = nodes.flatMap { node ->
                if (node !is Element) error("CSS 规则在属性取值后继续选择元素：$rule")
                when {
                    attribute -> listOf(when (segment) {
                        "text" -> node.text()
                        "ownText" -> node.ownText()
                        "textNodes" -> node.textNodes().joinToString("\n") { it.text() }
                        "html" -> node.html()
                        "all" -> node.outerHtml()
                        else -> node.attr(segment)
                    })
                    else -> {
                        var selector = segment.trim()
                        var positions: String? = null
                        var classes: List<String>? = null
                        if (!standard) {
                            val position = Regex("(?:\\.(-?\\d+(?::-?\\d+)*))|(?:!(-?\\d+(?::-?\\d+)*))$").find(selector)
                            if (position != null && position.range.last == selector.lastIndex) {
                                positions = (if (position.groupValues[2].isNotEmpty()) "!" else "") + position.groupValues[1].ifEmpty { position.groupValues[2] }
                                selector = selector.substring(0, position.range.first)
                            }
                            selector = when {
                                selector.startsWith("class.") -> { classes = selector.substring(6).trim().split(Regex("\\s+")); "*" }
                                selector.startsWith("id.") -> "[id=\"${selector.substring(3)}\"]"
                                selector.startsWith("tag.") -> selector.substring(4)
                                selector.startsWith("text.") -> ":containsOwn(${selector.substring(5)})"
                                else -> selector
                            }
                        }
                        val matches = if (classes != null) node.getAllElements().filter { it.classNames().containsAll(classes!!) } else if (selector == "children") node.children().toList() else node.select(selector).toList()
                        if (positions == null) matches else {
                            val excluded = positions.startsWith("!")
                            val indices = positions.removePrefix("!").split(':').mapNotNull { it.toIntOrNull() }.map { if (it < 0) matches.size + it else it }.toSet()
                            matches.filterIndexed { i, _ -> (i in indices) != excluded }
                        }
                    }
                }
            }
        }
        return nodes
    }
    private fun json(rule: String, input: Any): List<Any> {
        val parsed = if (input is String) JsonPath.parse(input) else JsonPath.parse(input)
        val value: Any? = try { parsed.read<Any>(rule) } catch (_: com.jayway.jsonpath.PathNotFoundException) { null }
        return when (value) { null -> emptyList(); is List<*> -> value.filterNotNull(); else -> listOf(value) }
    }
    private fun xpath(rule: String, input: Any): List<Any> {
        val document = W3CDom().namespaceAware(false).fromJsoup(Jsoup.parse(stringify(input), baseUrl))
        val evaluator = XPathFactory.newInstance().newXPath()
        return try {
            val nodes = evaluator.evaluate(if (rule.startsWith("/") && !rule.startsWith("//")) ".$rule" else rule, if (rule.startsWith("/") && !rule.startsWith("//")) evaluator.evaluate("//body/*[1]", document, XPathConstants.NODE) else document, XPathConstants.NODESET) as NodeList
            (0 until nodes.length).map { i ->
                val node = nodes.item(i)
                if (node.nodeType == org.w3c.dom.Node.ELEMENT_NODE) {
                    val transformer = javax.xml.transform.TransformerFactory.newInstance().newTransformer()
                    val writer = java.io.StringWriter()
                    transformer.transform(javax.xml.transform.dom.DOMSource(node), javax.xml.transform.stream.StreamResult(writer)); writer.toString().substringAfter("?>", writer.toString())
                } else node.nodeValue.orEmpty()
            }
        } catch (_: javax.xml.xpath.XPathExpressionException) { listOf(evaluator.evaluate(rule, document)) }
    }
    private fun regex(rule: String, input: Any): List<Any> = Regex(rule, RegexOption.DOT_MATCHES_ALL).findAll(stringify(input)).map { it.value }.toList()
    private fun String.removePrefixIgnoreCase(prefix: String) = if (startsWith(prefix, true)) substring(prefix.length) else this
    companion object {
        fun matchingBrace(text: String, start: Int): Int {
            var depth = 0; var quote: Char? = null; var escaped = false
            for (i in start until text.length) {
                val c = text[i]
                if (escaped) { escaped = false; continue }
                if (c == '\\') { escaped = true; continue }
                if (quote != null) { if (c == quote) quote = null; continue }
                if (c == '\'' || c == '"' || c == '`') { quote = c; continue }
                if (c == '{') depth++
                if (c == '}') { depth--; if (depth == 0) return i }
            }
            error("规则中的大括号未闭合")
        }
        /** Split only outside strings, selectors, regex character classes and JS blocks. */
        fun split(text: String, delimiter: String): List<String> {
            val output = mutableListOf<String>(); var begin = 0; var i = 0; var depth = 0; var quote: Char? = null; var escaped = false
            while (i < text.length) {
                val c = text[i]
                if (escaped) { escaped = false; i++; continue }
                if (c == '\\') { escaped = true; i++; continue }
                if (quote != null) { if (c == quote) quote = null; i++; continue }
                if (c == '\'' || c == '"' || c == '`') { quote = c; i++; continue }
                if (c in "([{") depth++
                if (c in ")]}") depth--
                if (depth == 0 && text.startsWith(delimiter, i)) { output.add(text.substring(begin, i)); i += delimiter.length; begin = i } else i++
            }
            output.add(text.substring(begin)); return output
        }
    }
}
