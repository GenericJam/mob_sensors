# Changelog

All notable changes to **mob_sensors** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **On-device self-test** (MOB-418). `MobSensors.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  makes one read-only `:mob_sensors_nif.list/0` call: a JSON sensor array
  passes (the iOS simulator's `[]` too), an Android bridge the bootstrap
  never wired fails, and so does a NIF that isn't linked. Run it with
  `mix mob.selftest` from a host app (mob_dev 0.7.17).

### Changed

- Requires mob >= 0.9.15 (was `~> 0.9.6`), for `Mob.Plugin.SelfTest`.
- **Android: the list NIF reports why it can't reach `SensorManager`.**
  `:mob_sensors_nif.list/0` answers `{:error, :bridge_not_registered}`
  (`MobSensorsBridge.register()` never ran or the `sensors_list` lookup
  failed), `{:error, :no_activity}` (no Activity handed to the bridge), or
  `:no_jni_env` / `:bridge_exception` / `:string_unavailable`, instead of
  `"[]"`. `MobSensors.list/0` still returns `[]` then, and now logs a
  warning with the reason.

## [0.1.0] - 2026-10-04

Initial release (MOB-389). Every phone sensor for Mob apps.

### Added

- `MobSensors.list/0`: every Android sensor (`getSensorList(TYPE_ALL)`,
  standard types as atoms, vendor sensors by their string type) and the iOS
  sensors the device has.
- `MobSensors.read/2` (one sample, `timeout_ms:`), `start/2` / `stop/1`
  (streaming, `interval_ms:`), delivering
  `{:mob_sensors, :reading, type, %{values, timestamp, accuracy}}` or
  `{:mob_sensors, :error, type, reason}` to the caller. Listeners stop when a
  read completes or times out, on `stop/1`, and when the caller exits.
- `MobSensors.steps/2`: step history from `CMPedometer` on iOS;
  `{:error, :history_unavailable}` on Android.
- The `:activity_recognition` permission capability for
  `Mob.Permissions.request/2` (Android `ACTIVITY_RECOGNITION`, iOS Motion &
  Fitness).
- Values in Android `SensorEvent` units on both platforms.
