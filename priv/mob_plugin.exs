%{
  name: :mob_sensors,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description:
    "Every phone sensor: list, one-shot read, streaming, step history " <>
      "(Android SensorManager; iOS CoreMotion, CMAltimeter, CMPedometer, proximity)",
  nifs: [
    # iOS: Objective-C NIF over CMMotionManager / CMAltimeter / CMPedometer and
    # UIDevice proximity monitoring. Also self-registers the
    # :activity_recognition permission handler (motion authorization) at load.
    %{module: :mob_sensors_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to SensorManager via the Kotlin MobSensorsBridge.
    %{module: :mob_sensors_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  permissions: [
    # iOS handler self-registered at NIF load (mob_sensors_request_permission ->
    # CMPedometer query, which raises the Motion & Fitness prompt); Android
    # mapping via MobSensorsBridge implementing MobPermissionProvider
    # (ACTIVITY_RECOGNITION on API 29+, nothing to grant below).
    %{capability: :activity_recognition, ios: %{handler: "mob_sensors_request_permission"}}
  ],
  android: %{
    bridge_kt: "priv/native/android/MobSensorsBridge.kt",
    bridge_class: "io.mob.sensors.MobSensorsBridge",
    # Step counter / step detector need it on API 29+. Every other sensor needs
    # no permission. Heart rate needs BODY_SENSORS, which this plugin does not
    # declare: a host that wants heart rate declares and requests it itself.
    permissions: ["android.permission.ACTIVITY_RECOGNITION"]
  },
  ios: %{
    frameworks: ["CoreMotion", "UIKit"],
    plist_keys: %{
      "NSMotionUsageDescription" =>
        "Motion data (steps, floors, barometric pressure) is read by this app."
    }
  }
}
