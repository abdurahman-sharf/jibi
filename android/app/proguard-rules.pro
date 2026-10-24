# Extra R8 rules for release builds. The Flutter Gradle plugin adds this file
# automatically; the rules of every plugin (Tink, AndroidX biometric, Gson, the
# Flutter engine) arrive through their own consumer rules.

# flutter_local_notifications persists scheduled notifications as JSON with Gson
# and reads them back after a reboot or an app update. Its model classes are
# read by reflection, so their members must keep their names.
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }
