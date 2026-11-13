package org.mewx.wenku8_flutter.legado

import org.json.JSONObject
import org.jsoup.Jsoup
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.Charset

/** One cookie jar per source. Never shares the Wenku account transport. */
class SourceHttp {
    private val cookies = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)
    data class Response(val url: String, val body: String, val bytes: ByteArray)
    fun request(raw: String, base: String, headers: Map<String, String> = emptyMap()): Response {
        val split = Regex(",\\s*(?=\\{)").find(raw)
        val options = split?.let { JSONObject(raw.substring(it.range.last + 1)) } ?: JSONObject()
        require(!options.optBoolean("webView") && !options.optBoolean("useWebView")) {
            "这个书源需要 WebView，当前版本尚未支持"
        }
        val address = if (split == null) raw else raw.substring(0, split.range.first)
        var uri = URI(base).resolve(address.trim().replace(" ", "%20"))
        var method = options.optString("method", "GET").uppercase()
        var body = options.opt("body")?.let { if (it == JSONObject.NULL) null else it.toString() }
        val custom = options.optJSONObject("headers") ?: options.optJSONObject("header")
        val allHeaders = headers.toMutableMap()
        custom?.keys()?.forEach { allHeaders[it] = custom.getString(it) }
        val charset = options.optString("charset", "UTF-8")
        repeat(8) {
            require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null) { "书源 URL 必须是 HTTP(S) 地址" }
            val connection = uri.toURL().openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 15000
                connection.readTimeout = 15000
                connection.instanceFollowRedirects = false
                connection.requestMethod = method
                connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36")
                cookies.get(uri, emptyMap()).forEach { (key, values) -> connection.setRequestProperty(key, values.joinToString("; ")) }
                allHeaders.forEach { (key, value) -> connection.setRequestProperty(key, value) }
                if (method != "GET" && method != "HEAD" && body != null) {
                    connection.doOutput = true
                    if (allHeaders.keys.none { it.equals("Content-Type", true) }) {
                        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=$charset")
                    }
                    connection.outputStream.use { it.write(body!!.toByteArray(Charset.forName(charset))) }
                }
                val status = connection.responseCode
                cookies.put(uri, connection.headerFields.filterKeys { it != null })
                if (status in setOf(301, 302, 303, 307, 308)) {
                    uri = uri.resolve(connection.getHeaderField("Location") ?: error("重定向缺少地址"))
                    // Credentials from one origin must not follow redirects to another.
                    if (uri.host != connection.url.host) allHeaders.keys.removeAll { it.equals("Authorization", true) || it.equals("Cookie", true) }
                    if (status == 303 || ((status == 301 || status == 302) && method == "POST")) { method = "GET"; body = null }
                } else {
                    check(status in 200..299) { "书源请求失败：HTTP $status" }
                    val bytes = connection.inputStream.use { stream ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            require(output.size() + count <= 8 * 1024 * 1024) { "书源响应超过 8 MiB" }
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                    val declared = Regex("charset\\s*=\\s*[\"']?([^;\\s\"']+)", RegexOption.IGNORE_CASE)
                        .find(connection.contentType.orEmpty())?.groupValues?.get(1)
                    val text = if (options.has("charset") || declared != null) {
                        bytes.toString(Charset.forName(if (options.has("charset")) charset else declared!!))
                    } else Jsoup.parse(java.io.ByteArrayInputStream(bytes), null, uri.toString()).let { doc ->
                        // Jsoup detects meta charset; retain original markup for JSON/regex rules.
                        bytes.toString(doc.charset())
                    }
                    return Response(uri.toString(), text.removePrefix("\uFEFF"), bytes)
                }
            } finally { connection.disconnect() }
        }
        error("书源重定向次数过多")
    }
    fun cookie(url: String): String = cookies.get(URI(url), emptyMap())["Cookie"]?.joinToString("; ").orEmpty()
    fun setCookie(url: String, value: String) { cookies.put(URI(url), mapOf("Set-Cookie" to listOf(value))) }
    companion object {
        fun encode(value: String, charset: String = "UTF-8"): String = URLEncoder.encode(value, charset)
    }
}
