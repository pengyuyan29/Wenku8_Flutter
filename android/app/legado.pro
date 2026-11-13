# Rhino calls the host bridge by its public method names.
-keep class org.mewx.wenku8_flutter.legado.JavaBridge { public *; }
-keep class org.mewx.wenku8_flutter.legado.JavaBridge$SourceResponse { public *; }
# Keep the interpreter's reflective entry points, excluding its desktop tools.
-keep class !org.mozilla.javascript.tools.**,org.mozilla.javascript.** { *; }
-dontwarn org.mozilla.javascript.tools.**
-dontwarn org.slf4j.impl.**
