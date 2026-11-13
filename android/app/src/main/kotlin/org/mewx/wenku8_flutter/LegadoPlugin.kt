package org.mewx.wenku8_flutter

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mewx.wenku8_flutter.legado.SourceEngine
import org.mewx.wenku8_flutter.legado.SourceHttp
import org.mewx.wenku8_flutter.legado.SourceChinese
import java.util.concurrent.Executors

class LegadoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val worker = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private val clients = java.util.concurrent.ConcurrentHashMap<String, SourceHttp>()
    private var chinese: SourceChinese? = null
    private var imageCache: java.io.File? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val assets = binding.applicationContext.assets
        fun dictionary(name: String) = assets.open("flutter_assets/assets/opencc/$name.txt").bufferedReader().use { it.readText() }
        chinese = SourceChinese(dictionary("STCharacters"), dictionary("TSCharacters"))
        imageCache = java.io.File(binding.applicationContext.cacheDir, "legado-images-v1").apply { mkdirs() }
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/legado").also { it.setMethodCallHandler(this) }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("search", "browse", "detail", "chapters", "content", "fetch", "image")) { result.notImplemented(); return }
        worker.execute {
            try {
                val args = (call.arguments as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value } ?: emptyMap()
                val source = args["source"] as? Map<*, *>
                val key = source?.get("bookSourceUrl")?.toString() ?: "subscription"
                val http = clients.computeIfAbsent(key) { SourceHttp() }
                val value: Any = if (call.method == "fetch") {
                    http.request(args["url"].toString(), args["url"].toString()).body
                } else if (call.method == "image") {
                    val identity = key + "\n" + args["url"].toString()
                    val digest = java.security.MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
                    val file = java.io.File(requireNotNull(imageCache), digest)
                    if (file.isFile && file.length() in 1..(8L * 1024 * 1024)) {
                        file.setLastModified(System.currentTimeMillis()); file.readBytes()
                    } else {
                        val bytes = SourceEngine(http, chinese).run("image", args) as ByteArray
                        synchronized(this) {
                            val temp = java.io.File(file.path + ".tmp")
                            temp.writeBytes(bytes)
                            if (!temp.renameTo(file)) temp.delete()
                            val files = imageCache?.listFiles()?.filter { !it.name.endsWith(".tmp") }?.sortedBy { it.lastModified() }.orEmpty()
                            var size = files.sumOf { it.length() }
                            for (old in files) { if (size <= 64L * 1024 * 1024) break; size -= old.length(); old.delete() }
                        }
                        bytes
                    }
                } else SourceEngine(http, chinese).run(call.method, args)
                main.post { if (channel != null) result.success(value) }
            } catch (failure: Exception) {
                val message = failure.message?.take(600) ?: "书源执行失败"
                main.post { if (channel != null) result.error("source_error", message, null) }
            }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null); channel = null; worker.shutdownNow()
    }
}
