# Rhino calls the host bridge by its public method names.
-keep class org.mewx.wenku8_flutter.legado.JavaBridge { public *; }
-keep class org.mewx.wenku8_flutter.legado.JavaBridge$SourceResponse { public *; }
# Keep the interpreter's reflective entry points, excluding its desktop tools.
-keep class !org.mozilla.javascript.tools.**,org.mozilla.javascript.** { *; }
-dontwarn org.mozilla.javascript.tools.**
-dontwarn org.slf4j.impl.**
# Optional JavaBeans JSON conversion is unused by the interpreter/host bridge.
# Android has no java.beans implementation.
-dontwarn java.beans.BeanDescriptor
-dontwarn java.beans.BeanInfo
-dontwarn java.beans.IntrospectionException
-dontwarn java.beans.Introspector
-dontwarn java.beans.PropertyDescriptor
