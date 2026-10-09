defmodule MobSensors.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One read-only native call, `:mob_sensors_nif.list/0` (what
  `MobSensors.list/0` decodes). It starts no listener and raises no
  permission prompt, so there is nothing to undo and no user to wait for.

    * **iOS:** the Objective-C NIF is linked and answers with the sensors
      CoreMotion, `CMAltimeter`, `CMPedometer` and `UIDevice` report on this
      device. The simulator has none, so `[]` is its answer.
    * **Android:** the zig NIF answers `{:error, :bridge_not_registered}`
      until `MobSensorsBridge.register()` has cached the bridge class and its
      `sensors_list` method, and `{:error, :no_activity}` until the bootstrap
      handed the bridge an Activity. After that the answer comes from
      `SensorManager.getSensorList(TYPE_ALL)` through Kotlin.

  A JSON array of sensor entries passes, empty or not: either proves the
  native side initialized, and a device without sensors is not a broken
  plugin. Every `{:error, _}` fails, since `MobSensors.list/0` and every
  read would come back empty or `:unavailable` in that host. So does
  anything that isn't a sensor array, and the host stub's `nif_not_loaded`
  (the NIF isn't linked into the build); any other raise propagates, which
  the runner also counts as a failure. The test never skips.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(_ctx) do
    classify(:mob_sensors_nif.list())
  rescue
    e in ErlangError ->
      case e do
        %ErlangError{original: :nif_not_loaded} ->
          {:fail, "mob_sensors_nif is not linked into this build: #{Exception.message(e)}"}

        _other ->
          reraise e, __STACKTRACE__
      end
  end

  @doc false
  # Maps a :mob_sensors_nif.list/0 answer to a self-test result.
  @spec classify(term()) :: Mob.Plugin.SelfTest.result()
  def classify(answer)

  def classify(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, entries} when is_list(entries) ->
        if Enum.all?(entries, &sensor_entry?/1),
          do: :pass,
          else: {:fail, "list/0 returned #{inspect(json)}, expected a JSON array of sensors"}

      _other ->
        {:fail, "list/0 returned #{inspect(json)}, expected a JSON array of sensors"}
    end
  end

  def classify({:error, :bridge_not_registered}),
    do:
      {:fail,
       "Kotlin MobSensorsBridge not registered (nativeRegister never ran or a method-ID lookup failed)"}

  def classify({:error, :no_activity}),
    do: {:fail, "MobSensorsBridge has no Activity (MobActivityAware.setActivity never called)"}

  def classify({:error, reason}),
    do: {:fail, "list/0 could not reach SensorManager: #{inspect(reason)}"}

  def classify(other),
    do: {:fail, "list/0 returned #{inspect(other)}, expected a JSON array of sensors"}

  # Both natives write an integer "type" (the Android Sensor.TYPE_* code) for
  # every sensor; the other fields may be null.
  defp sensor_entry?(%{"type" => type}) when is_integer(type), do: true
  defp sensor_entry?(_entry), do: false
end
