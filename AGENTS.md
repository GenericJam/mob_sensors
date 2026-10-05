# mob_sensors — Agent Instructions

You're in **mob_sensors**, a Mob plugin that exposes every phone sensor:
`MobSensors.list/0`, one-shot `read/2`, streaming `start/2` / `stop/1`, and
step history `steps/2`. Android uses `SensorManager` through the Kotlin bridge
`io.mob.sensors.MobSensorsBridge`; iOS uses CoreMotion (`CMMotionManager`,
`CMAltimeter`, `CMPedometer`) and `UIDevice` proximity monitoring.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view:
the plugin manifest schema, how to drive a running app, release rules.

> **Keep this file current.** When you change a message shape, an option, or
> hit a gotcha, fix it here in the same commit.

## Anatomy

* `lib/mob_sensors.ex` — public API and the reference for message shapes,
  units and the per-platform table. Message-shape changes land here first.
* `lib/mob_sensors/server.ex` — `MobSensors.Server`, started by
  `MobSensors.Application` (mob ≥ 0.9.6 starts plugin OTP apps on device). It
  is the only caller of the NIF: it allocates an integer handle per
  listener, receives the NIF's `{:mob_sensors_native, handle, ...}` messages,
  forwards `{:mob_sensors, ...}` to the caller, monitors every caller, and
  stops native listeners on read completion, timeout, `stop/1` or caller
  exit. At init it calls `stop_all/0` to drop listeners a crashed previous
  server left behind.
* `lib/mob_sensors/types.ex` — atom ⇄ Android `Sensor.TYPE_*` code table and
  units. Both natives speak those codes (iOS answers to 1, 2, 4, 6, 8, 19).
  Never create atoms from native strings: unknown codes become the sensor's
  string type.
* `src/mob_sensors_nif.erl` — NIF stub: `list/0`, `start/4`, `stop/1`,
  `stop_all/0`, `steps/3`. Documents the native message shapes. On a host
  build every call raises `nif_not_loaded`, which the server maps to `[]` /
  `{:error, :unavailable}`.
* `priv/native/jni/mob_sensors_nif.zig` + `priv/native/android/MobSensorsBridge.kt`
  — Android. `sensors_start` result codes are 1 ok / 2 unavailable /
  3 permission (non-zero so a throwing call, which returns 0, can't read as
  ok). Readings run on a `HandlerThread`, not the main thread.
* `priv/native/ios/mob_sensors_nif.m` — iOS. Converts to Android units/axes
  (acceleration × −9.80665, pressure kPa × 10). One shared `CMMotionManager`
  (Apple allows one per app): raw accelerometer, and device motion for the
  bias-corrected gyroscope and calibrated magnetic field. Each stream runs at
  the fastest handle's interval and `fan_out` throttles slower handles.
  Registry and motion state live on one serial dispatch queue (the CoreMotion
  operation queue runs on it); proximity work on the main queue. Each
  permission request keeps its own CoreMotion object until it replies.
* `priv/mob_plugin.exs` — manifest: the two NIFs, the
  `:activity_recognition` capability, `ACTIVITY_RECOGNITION`,
  `NSMotionUsageDescription`, CoreMotion.

## Gotchas

1. **Step sensors need `:activity_recognition`.** Without it a read delivers
   `{:mob_sensors, :error, type, :permission}`. Android checks it before
   registering; iOS reports it from the CoreMotion error.
2. **iOS has no ambient-light API.** Don't add one through private API.
3. **iOS proximity blanks the screen** while near. Monitoring is reference
   counted across handles and switched off with the last one, unless the app
   had it on already. `proximityState` reads far until the sensor settles, so
   the first sample waits up to 0.3 s after monitoring is switched on.
4. **Android 12+ caps sampling at 200 Hz** without
   `HIGH_SAMPLING_RATE_SENSORS`, hence the 5 ms `interval_ms` floor.
5. **The emulator simulates sensors**: `adb emu sensor set pressure 1001.5`
   (also `light`, `proximity`, `humidity`, `temperature`,
   `acceleration x:y:z`, ...). It has no step counter, so on it
   `read(:step_counter)` is `:permission` before the grant and
   `{:error, :unavailable}` after. Its ambient temperature sensor reports
   `-1.0e30` on every fresh registration; set a new value while a stream is
   running to see it (an emulator HAL quirk, not filtered by the plugin).
6. **The iOS simulator has no sensors**: `list/0` is `[]`, reads are
   `{:error, :unavailable}`, `:activity_recognition` reports `:denied`.
7. **iPad has no pedometer**, so the Motion & Fitness prompt is raised through
   `CMAltimeter` there.

## Testing

```bash
mix setup   # deps.get + activate .githooks
mix test
```

`test/mob_sensors/server_test.exs` drives the server with a fake native
module (the real message shapes, timeouts, caller-exit cleanup);
`test/mob_sensors_test.exs` covers the manifest, the NIF stub, the host
fallback and type mapping. Native code is only exercised by a
`mix mob.deploy --native` of a host app with this plugin as a path dep.

## Worktrees

Work in `../mob_sensors-worktrees/<branch>`, never the main checkout. The git
stash stack is shared across worktrees: never bare `git stash`.

## Release

`version` in `mix.exs` on master triggers `.github/workflows/release.yml`
(tag, GitHub Release, signed Hex publish). Bump only when the latest `tests`
run on master is green, then confirm with `mix hex.info mob_sensors`.
