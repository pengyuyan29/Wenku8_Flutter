import org.json.JSONArray
import org.mewx.wenku8_flutter.legado.*
import java.io.File

/** Opt-in live check; never bundles a user's source subscription into the app. */
fun main(args: Array<String>) {
    val all = JSONArray(File(args[0]).readText())
    val source = all.getJSONObject(args[1].toInt()).toMap()
    val dictionary = File("../../assets/opencc")
    val chinese = SourceChinese(File(dictionary, "STCharacters.txt").readText(), File(dictionary, "TSCharacters.txt").readText())
    val engine = SourceEngine(SourceHttp(), chinese)
    println("Source: ${source["bookSourceName"]}")
    val result = engine.run("search", mapOf("source" to source, "query" to args.getOrElse(2) { "斗破" }, "page" to 1)) as Map<*, *>
    val books = result["items"] as List<*>
    println("Search results: ${books.size}")
    check(books.isNotEmpty()) { "Live search is empty; site may be unavailable or source rules changed" }
    val book = books.first() as Map<*, *>
    val detail = engine.run("detail", mapOf("source" to source, "book" to book)) as Map<*, *>
    println("Detail parsed")
    val chapters = engine.run("chapters", mapOf("source" to source, "book" to (book + detail.filterValues { it != "" }))) as List<*>
    println("Chapters: ${chapters.size}")
    check(chapters.isNotEmpty())
    val body = engine.run("content", mapOf("source" to source, "book" to book, "chapter" to chapters.first(), "nextChapterUrl" to (chapters.getOrNull(1) as? Map<*, *>)?.get("url"))) as String
    println("Body characters: ${body.length}")
    check(body.isNotBlank())
}
