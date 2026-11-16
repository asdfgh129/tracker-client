# TrackerOne 混淆规则。
#
# 极光推送：厂商通道回调通过反射调用，必须保留。
-keep class cn.jpush.** { *; }
-keep class cn.jiguang.** { *; }
-keep class com.huawei.** { *; }
-keep class com.xiaomi.** { *; }
-keep class com.heytap.** { *; }
-keep class com.vivo.** { *; }
-keep class com.hihonor.** { *; }

# 高德地图 SDK
-keep class com.amap.api.** { *; }
-keep class com.autonavi.** { *; }
-keep class com.loc.** { *; }

# flutter_local_notifications
-keep class com.dexterous.** { *; }

# Traccar Client SDK（定位与队列）
-keep class org.traccar.client.** { *; }

# 腾讯 Bugly（崩溃上报，官方混淆规则）
-dontwarn com.tencent.bugly.**
-keep class com.tencent.bugly.** { *; }

# 保留注解与泛型签名（Gson/Jackson 风格序列化所需）
-keepattributes Signature, *Annotation*
