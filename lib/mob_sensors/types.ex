defmodule MobSensors.Types do
  @moduledoc """
  Sensor type mapping between `MobSensors` types and the native layer.

  The native layer speaks Android's `Sensor.TYPE_*` integers on both
  platforms (the iOS NIF reports its sensors under the same codes). Standard
  types map to atoms; anything else (vendor sensors, types newer than this
  table) is identified by the sensor's string type, e.g.
  `"com.motorola.sensor.x"`. Atoms are never created from native strings.
  """

  # Android Sensor.TYPE_* constants (public API ones only; hidden types such as
  # TYPE_TILT_DETECTOR surface as their string type).
  @codes [
    accelerometer: 1,
    magnetic_field: 2,
    orientation: 3,
    gyroscope: 4,
    light: 5,
    pressure: 6,
    temperature: 7,
    proximity: 8,
    gravity: 9,
    linear_acceleration: 10,
    rotation_vector: 11,
    relative_humidity: 12,
    ambient_temperature: 13,
    magnetic_field_uncalibrated: 14,
    game_rotation_vector: 15,
    gyroscope_uncalibrated: 16,
    significant_motion: 17,
    step_detector: 18,
    step_counter: 19,
    geomagnetic_rotation_vector: 20,
    heart_rate: 21,
    pose_6dof: 28,
    stationary_detect: 29,
    motion_detect: 30,
    heart_beat: 31,
    low_latency_offbody_detect: 34,
    accelerometer_uncalibrated: 35,
    hinge_angle: 36,
    head_tracker: 37,
    accelerometer_limited_axes: 38,
    gyroscope_limited_axes: 39,
    accelerometer_limited_axes_uncalibrated: 40,
    gyroscope_limited_axes_uncalibrated: 41,
    heading: 42
  ]

  @by_code Map.new(@codes, fn {atom, code} -> {code, atom} end)
  @by_atom Map.new(@codes)

  # Units match Android's SensorEvent values (the iOS NIF converts to them).
  @units %{
    accelerometer: "m/s²",
    accelerometer_uncalibrated: "m/s²",
    accelerometer_limited_axes: "m/s²",
    accelerometer_limited_axes_uncalibrated: "m/s²",
    gravity: "m/s²",
    linear_acceleration: "m/s²",
    gyroscope: "rad/s",
    gyroscope_uncalibrated: "rad/s",
    gyroscope_limited_axes: "rad/s",
    gyroscope_limited_axes_uncalibrated: "rad/s",
    magnetic_field: "µT",
    magnetic_field_uncalibrated: "µT",
    pressure: "hPa",
    light: "lx",
    proximity: "cm",
    relative_humidity: "%",
    ambient_temperature: "°C",
    temperature: "°C",
    orientation: "°",
    hinge_angle: "°",
    heading: "°",
    heart_rate: "bpm",
    step_counter: "steps",
    step_detector: "steps"
  }

  @typedoc "A standard sensor atom or an Android vendor string type."
  @type t :: atom() | String.t()

  # The Android NIF copies a vendor type into a 256-byte NUL-terminated buffer.
  @max_string_type_bytes 255

  @doc """
  Maps a requested type to the native `{type_code, string_type}` pair:
  `{code, nil}` for a standard atom, `{-1, string}` for a vendor string (valid
  UTF-8, 1 to #{@max_string_type_bytes} bytes).
  """
  @spec to_native(term()) :: {:ok, {integer(), String.t() | nil}} | {:error, :unknown_type}
  def to_native(type) when is_atom(type) do
    case Map.fetch(@by_atom, type) do
      {:ok, code} -> {:ok, {code, nil}}
      :error -> {:error, :unknown_type}
    end
  end

  def to_native(type)
      when is_binary(type) and type != "" and byte_size(type) <= @max_string_type_bytes do
    if String.valid?(type), do: {:ok, {-1, type}}, else: {:error, :unknown_type}
  end

  def to_native(_type), do: {:error, :unknown_type}

  @doc """
  The `MobSensors` type for a native sensor: the atom for a standard code,
  otherwise the sensor's string type.
  """
  @spec from_native(integer(), String.t() | nil) :: t()
  def from_native(code, string_type) do
    case Map.fetch(@by_code, code) do
      {:ok, atom} -> atom
      :error -> string_type || "unknown:#{code}"
    end
  end

  @doc "The unit of a type's values, or `nil` (unitless, vendor, unknown)."
  @spec unit(t()) :: String.t() | nil
  def unit(type) when is_atom(type), do: Map.get(@units, type)
  def unit(_type), do: nil
end
