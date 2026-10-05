defmodule MobSensors do
  @moduledoc """
  Every phone sensor for Mob apps: list what the device has, read one sample,
  stream readings, and query step history.

  All functions can be called from any process (a screen, a GenServer, an
  agent tool). Results are sent to the **calling process**:

      {:mob_sensors, :reading, type, %{values: [float()], timestamp: unix_ms, accuracy: integer() | nil}}
      {:mob_sensors, :error, type, reason}       # :timeout | :permission | :unavailable | String.t()
      {:mob_sensors, :steps, {:ok, %{steps: n, distance_m: float | nil, floors_ascended: n | nil, from: ms, to: ms}}}
      {:mob_sensors, :steps, {:error, reason}}   # :timeout | :permission | :unavailable | String.t()

  `type` in a message is exactly the type you asked for (an atom such as
  `:pressure`, or an Android vendor string such as `"com.motorola.sensor.x"`).
  An error message ends the read or stream it belongs to.

  ## Example

      :ok = MobSensors.read(:pressure)

      receive do
        {:mob_sensors, :reading, :pressure, %{values: [hpa]}} -> hpa
        {:mob_sensors, :error, :pressure, reason} -> {:error, reason}
      end

  ## Types and units

  Types are Android's sensor types: `:accelerometer`, `:gyroscope`,
  `:magnetic_field`, `:pressure`, `:light`, `:proximity`, `:step_counter`,
  `:step_detector`, `:gravity`, `:linear_acceleration`, `:rotation_vector`,
  `:game_rotation_vector`, `:geomagnetic_rotation_vector`,
  `:relative_humidity`, `:ambient_temperature`, `:significant_motion`,
  `:heart_rate`, `:accelerometer_uncalibrated`, `:gyroscope_uncalibrated`,
  `:magnetic_field_uncalibrated`, `:hinge_angle`, `:heading` and the other
  public `Sensor.TYPE_*` constants (see `MobSensors.Types`). A sensor with no
  standard type is named by its Android string type. Values use Android's
  `SensorEvent` layout and units on both platforms:

  | Type | `values` | Unit |
  |---|---|---|
  | `:accelerometer`, `:gravity`, `:linear_acceleration` | `[x, y, z]` | m/s² (gravity included in `:accelerometer`; +9.81 on z when lying face-up) |
  | `:gyroscope` | `[x, y, z]` | rad/s |
  | `:magnetic_field` | `[x, y, z]` | µT |
  | `:pressure` | `[p]` | hPa |
  | `:light` | `[lux]` | lx |
  | `:proximity` | `[distance]` | cm (many sensors are binary: `0.0` near, `max_range` far) |
  | `:relative_humidity` | `[percent]` | % |
  | `:ambient_temperature` | `[celsius]` | °C |
  | `:step_counter` | `[steps]` | Android: steps since boot. iOS: steps since the local midnight before the read or stream started |
  | `:step_detector` | `[1.0]` per step | |
  | `:rotation_vector` family | `[x, y, z, w, accuracy]` | unitless |

  `timestamp` is Unix time in milliseconds. `accuracy` is Android's
  `SensorManager.SENSOR_STATUS_*` (`-1` no contact, `0` unreliable, `1` low,
  `2` medium, `3` high). It is `nil` where the platform has none: iOS, except
  for `:magnetic_field` (its calibration accuracy), and Android trigger
  sensors such as `:significant_motion`.

  ## Platforms

  | Sensor | Android | iOS |
  |---|---|---|
  | `list/0` | every sensor from `SensorManager.getSensorList(TYPE_ALL)` | the sensors below that the device has |
  | accelerometer | `SensorManager` | `CMMotionManager` raw accelerometer (converted from g to m/s² with Android's sign) |
  | gyroscope / magnetic field | `SensorManager` | `CMMotionManager` device motion (bias-corrected rotation rate; calibrated field) |
  | pressure (barometer) | `SensorManager` | `CMAltimeter` (kPa converted to hPa; ~1 Hz) |
  | proximity | `SensorManager` | `UIDevice` proximity monitoring (iPhone only): near → `[0.0]`, far → `[5.0]` |
  | step counter | `SensorManager` (steps since boot) | `CMPedometer` (steps since local midnight) |
  | step history (`steps/2`) | `{:error, :history_unavailable}` (needs Health Connect) | `CMPedometer` query |
  | light, humidity, temperature, gravity, rotation vectors, vendor sensors… | `SensorManager` | not available |

  iOS has **no public ambient-light API**, so `:light` is never listed or
  readable there. Enabling proximity monitoring on iOS blanks the screen while
  something is near it (system behaviour); it is turned off again when the
  last proximity read or stream ends, unless the app had already enabled it.
  The iOS simulator has none of these sensors: `list/0` returns `[]` and reads
  return `{:error, :unavailable}`.

  ## Permissions

  Step counter and step detector need the `:activity_recognition` capability,
  which this plugin registers with Mob's permission registry:

      Mob.Permissions.request(socket, :activity_recognition)
      # -> {:permission, :activity_recognition, :granted | :denied}

  Android: `ACTIVITY_RECOGNITION` on API 29+ (declared by this plugin's
  manifest; nothing to grant below API 29). iOS: Motion & Fitness
  authorization (`NSMotionUsageDescription`, merged from this plugin's
  manifest). On iOS the same grant also gates the barometer (`:pressure`) and
  `steps/2`; request it first, since a read made while the system prompt is
  still up can time out. Without the grant a read delivers
  `{:mob_sensors, :error, type, :permission}` rather than crashing.

  Heart rate on Android needs `BODY_SENSORS`, or
  `android.permission.health.READ_HEART_RATE` for apps targeting Android 16+.
  This plugin declares neither and `Mob.Permissions` has no capability for
  them, so a host that wants heart rate declares the permission and obtains
  the grant through its own code.

  All other sensors need no permission.
  """

  alias MobSensors.{Server, Types}

  @typedoc "A standard sensor atom (see `MobSensors.Types`) or an Android vendor string type."
  @type type :: Types.t()

  @type info :: %{
          type: type(),
          name: String.t(),
          vendor: String.t() | nil,
          unit: String.t() | nil,
          max_range: float() | nil,
          resolution: float() | nil,
          wake_up: boolean() | nil
        }

  @type reading :: %{values: [float()], timestamp: integer(), accuracy: integer() | nil}

  @default_timeout_ms 3_000
  # Process.send_after/3 accepts at most 2^32 - 1 ms.
  @max_timeout_ms 4_294_967_295
  @default_interval_ms 200
  # Android 12+ rejects rates above 200 Hz without HIGH_SAMPLING_RATE_SENSORS.
  @min_interval_ms 5
  # The native layer takes the period in microseconds as a 32-bit int.
  @max_interval_ms 2_147_483
  # Year 9999 in Unix ms: keeps steps/2 arguments well inside int64.
  @max_unix_ms 253_402_300_799_999

  @doc """
  Every sensor the device exposes. Synchronous.

  On Android this is the full `getSensorList(TYPE_ALL)`, including vendor
  sensors (their `type` is the vendor string). On iOS it lists the sensors
  this plugin can read that the device has. `[]` where no native layer is
  linked (host builds, tests) or on the iOS simulator.
  """
  @spec list() :: [info()]
  def list, do: Server.list(Server)

  @doc """
  Reads one sample of `type`; it arrives as a
  `{:mob_sensors, :reading, type, reading}` message, or
  `{:mob_sensors, :error, type, reason}` (`:timeout`, `:permission`,
  `:unavailable` or a platform message).

  Options:

    * `:timeout_ms` — how long to wait for the first sample (default
      #{@default_timeout_ms}, at most #{@max_timeout_ms}). On-change sensors
      (proximity, step counter, significant motion) report only when their
      value changes, though Android delivers the current value of most of them
      on registration.

  Returns `{:error, :unknown_type}` for a type this plugin doesn't know and
  `{:error, :unavailable}` when the device has no such sensor.
  """
  @spec read(type(), keyword()) :: :ok | {:error, :unavailable | :unknown_type}
  def read(type, opts \\ []) do
    timeout = bounded_integer!(opts, :timeout_ms, @default_timeout_ms, 1, @max_timeout_ms)
    Server.read(Server, type, timeout)
  end

  @doc """
  Streams `{:mob_sensors, :reading, type, reading}` messages to the caller
  until `stop/1`, the caller exits, or an error message ends it. Starting a
  type the caller already streams replaces that stream.

  Options:

    * `:interval_ms` — requested sampling interval (default
      #{@default_interval_ms}; values below #{@min_interval_ms} are raised to
      it; at most #{@max_interval_ms}). A hint: the OS may deliver faster or
      slower, and on-change sensors only report changes.
  """
  @spec start(type(), keyword()) :: :ok | {:error, :unavailable | :unknown_type}
  def start(type, opts \\ []) do
    interval =
      opts
      |> bounded_integer!(:interval_ms, @default_interval_ms, 1, @max_interval_ms)
      |> max(@min_interval_ms)

    Server.start(Server, type, interval)
  end

  @doc "Stops the caller's stream of `type`. Idempotent."
  @spec stop(type()) :: :ok
  def stop(type), do: Server.stop(Server, type)

  @doc """
  Queries step history between two Unix-millisecond times. The result
  arrives as `{:mob_sensors, :steps, {:ok, map}}` or
  `{:mob_sensors, :steps, {:error, reason}}` (`:timeout` after 10 s without
  an answer).

  iOS answers from `CMPedometer` (about the last 7 days are kept), e.g. today
  so far:

      now = System.os_time(:millisecond)
      MobSensors.steps(midnight_ms, now)   # midnight_ms: local midnight, Unix ms

  Android keeps no step history without Health Connect, so it returns
  `{:error, :history_unavailable}` (no message follows); `read(:step_counter)`
  gives steps since boot instead. `{:error, :unavailable}` when the device
  can't count steps.
  """
  @spec steps(integer(), integer()) :: :ok | {:error, :unavailable | :history_unavailable}
  def steps(from_ms, to_ms)
      when is_integer(from_ms) and is_integer(to_ms) and 0 <= from_ms and from_ms <= to_ms and
             to_ms <= @max_unix_ms do
    Server.steps(Server, from_ms, to_ms)
  end

  def steps(from_ms, to_ms) do
    raise ArgumentError,
          "steps/2 expects Unix milliseconds with 0 <= from <= to, got: " <>
            "#{inspect(from_ms)}, #{inspect(to_ms)}"
  end

  defp bounded_integer!(opts, key, default, min, max) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n >= min and n <= max ->
        n

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be an integer in #{min}..#{max}, got: #{inspect(other)}"
    end
  end
end
