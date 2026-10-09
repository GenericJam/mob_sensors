# mob_sensors

Every phone sensor for [Mob](https://hexdocs.pm/mob) apps: list the device's
sensors, read one sample, stream readings, and query step history. Android
(`SensorManager`, every sensor including vendor ones) and iOS (CoreMotion,
`CMAltimeter`, `CMPedometer`, proximity).

## Install

```elixir
# mix.exs
{:mob_sensors, "~> 0.2"}
```

```elixir
# mob.exs
config :mob, :plugins, [:mob_sensors]

config :mob, :trusted_plugins, %{
  # ...the other first-party plugins...
  mob_sensors: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}
```

Then `mix mob.deploy --native`: the plugin's NIFs reach the device only
through a native build.

Run `mix mob.selftest` from a host app (mob_dev 0.7.17+) to check on a device
that the native side is linked and wired up (`MobSensors.SelfTest`, one
read-only sensor-list call: no listener, no permission prompt).

## Use

Call from any process; results arrive in that process's mailbox.

```elixir
MobSensors.list()
#=> [%{type: :pressure, name: "...", vendor: "...", unit: "hPa", max_range: 1100.0,
#      resolution: 0.005, wake_up: false}, ...]

:ok = MobSensors.read(:pressure)
# {:mob_sensors, :reading, :pressure, %{values: [1013.2], timestamp: 1791100000000, accuracy: 3}}

:ok = MobSensors.start(:accelerometer, interval_ms: 100)
# {:mob_sensors, :reading, :accelerometer, %{values: [x, y, z], ...}} every ~100 ms
:ok = MobSensors.stop(:accelerometer)

:ok = MobSensors.read("com.motorola.sensor.x")   # a vendor sensor, by its string type

MobSensors.steps(midnight_ms, now_ms)            # iOS; Android: {:error, :history_unavailable}
# {:mob_sensors, :steps, {:ok, %{steps: 4321, distance_m: 3010.5, floors_ascended: 3,
#                               from: midnight_ms, to: now_ms}}}
```

Errors arrive as `{:mob_sensors, :error, type, reason}` with `reason` one of
`:timeout`, `:permission`, `:unavailable` or a platform message. `read/2`
and `start/2` return `{:error, :unknown_type}` or `{:error, :unavailable}`
straight away when the type is unknown or the device lacks the sensor.

A stream ends when its caller calls `stop/1` or exits; nothing leaks.

## Permissions

Step counter and step detector need `:activity_recognition`:

```elixir
Mob.Permissions.request(socket, :activity_recognition)
# {:permission, :activity_recognition, :granted | :denied}
```

Android: `ACTIVITY_RECOGNITION` (API 29+), declared by the plugin. iOS:
Motion & Fitness (`NSMotionUsageDescription`, merged from the plugin); it
also covers the barometer and `steps/2`. Every other sensor needs nothing.
Android heart rate needs `BODY_SENSORS`, which the host must declare and
request itself.

## Platforms

| Sensor | Android | iOS |
|---|---|---|
| accelerometer, gyroscope, magnetic field | yes | yes (`CMMotionManager`) |
| pressure (barometer) | yes | yes (`CMAltimeter`, ~1 Hz) |
| proximity | yes | iPhone only: near `[0.0]`, far `[5.0]` cm |
| step counter | steps since boot | steps since local midnight (`CMPedometer`) |
| step history, `steps/2` | `{:error, :history_unavailable}` | yes |
| ambient light | yes | **no public API** |
| humidity, temperature, gravity, rotation vectors, hinge angle, heart rate, vendor sensors | yes | no |

Values use Android's `SensorEvent` units and axes on both platforms (iOS
acceleration is converted from g to m/s² with Android's sign, pressure from
kPa to hPa). The iOS simulator has none of these sensors. See the `MobSensors`
moduledoc for the full message shapes and value layouts.

## License

MIT
