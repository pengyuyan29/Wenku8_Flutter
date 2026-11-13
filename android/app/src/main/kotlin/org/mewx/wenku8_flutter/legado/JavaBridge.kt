package org.mewx.wenku8_flutter.legado

import java.net.URLDecoder
import java.nio.charset.Charset
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONObject

/** Synchronous host methods run exclusively on the source worker. */
class JavaBridge(private val rules: RuleEvaluator) {
    fun t2s(value: String): String = rules.chinese?.convert(value, false) ?: value
    fun s2t(value: String): String = rules.chinese?.convert(value, true) ?: value
    fun setContent(value: String) { rules.content = value }
    fun getHeaderMap(): Map<String, String> = rules.headers
    fun randomUUID(): String = java.util.UUID.randomUUID().toString()
    fun ajax(url: String): String = rules.http.request(url, rules.baseUrl, rules.headers).body
    fun connect(url: String): SourceResponse = rules.http.request(url, rules.baseUrl, rules.headers).let { SourceResponse(it.body, it.url) }
    fun get(key: String): String = rules.variables[key].orEmpty()
    fun put(key: String, value: Any?): String = rules.stringify(value).also { rules.variables[key] = it }
    fun getString(rule: String): String = rules.text(rule)
    fun getStringList(rule: String): List<String> = rules.values(rule).map(rules::stringify)
    fun getElements(rule: String): List<Any> = rules.values(rule)
    fun getElement(rule: String): Any? = rules.values(rule).firstOrNull()
    fun base64Decode(value: String): String = String(Base64.getMimeDecoder().decode(value), Charsets.UTF_8)
    fun base64Encode(value: String): String = Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8))
    fun md5Encode(value: String): String = MessageDigest.getInstance("MD5").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    fun md5Encode16(value: String): String = md5Encode(value).substring(8, 24)
    @JvmOverloads fun encodeURI(value: String, charset: String = "UTF-8"): String = SourceHttp.encode(value, charset)
    @JvmOverloads fun encodeURIComponent(value: String, charset: String = "UTF-8"): String = SourceHttp.encode(value, charset).replace("+", "%20")
    @JvmOverloads fun decodeURI(value: String, charset: String = "UTF-8"): String = URLDecoder.decode(value, charset)
    fun htmlFormat(value: String): String = org.jsoup.Jsoup.parse(value).text()
    fun getCookie(url: String): String = rules.http.cookie(url)
    fun log(value: Any?): String = rules.stringify(value)
    fun toNum(value: String): Double = Regex("-?\\d+(?:\\.\\d+)?").find(value)?.value?.toDoubleOrNull() ?: 0.0
    class SourceResponse(private val text: String, private val address: String) {
        fun body(): String = text
        fun url(): String = address
    }
}
