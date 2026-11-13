package org.mewx.wenku8_flutter.legado

/** Source scripts use the same OpenCC dictionary family as the Flutter reader. */
class SourceChinese(st: String, ts: String) {
    private fun dictionary(text: String): Map<Char, String> = text.lineSequence().filter { !it.startsWith('#') }.mapNotNull { line ->
        val parts = line.split('\t'); if (parts.size < 2 || parts[0].length != 1) null else parts[0][0] to parts[1].substringBefore(' ')
    }.toMap()
    private val simplified = dictionary(ts)
    private val traditional = dictionary(st)
    fun convert(text: String, toTraditional: Boolean): String {
        val table = if (toTraditional) traditional else simplified
        return buildString { text.forEach { append(table[it] ?: it.toString()) } }
    }
}
