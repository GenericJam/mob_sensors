defmodule MobSensorsTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobSensors.{SelfTest, Types}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads, validates clean and passes the pre-publish validator", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares one NIF module for both platforms", %{manifest: m} do
      assert [ios, android] = m.nifs
      assert %{module: :mob_sensors_nif, platform: :ios, lang: :objc} = ios
      assert %{module: :mob_sensors_nif, platform: :android, lang: :zig} = android
    end

    test "owns :activity_recognition: iOS handler, Android permission, iOS motion plist key",
         %{manifest: m} do
      assert [
               %{
                 capability: :activity_recognition,
                 ios: %{handler: "mob_sensors_request_permission"}
               }
             ] =
               m.permissions

      assert "android.permission.ACTIVITY_RECOGNITION" in m.android.permissions
      assert Map.has_key?(m.ios.plist_keys, "NSMotionUsageDescription")
    end

    test "every native source dir and the Kotlin bridge exist", %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end

    test "declares the self-test, which passes the validator without a warning", %{manifest: m} do
      assert m.selftest == MobSensors.SelfTest
      assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
      refute Enum.any?(warnings, &(&1 =~ "selftest"))
    end
  end

  describe "MobSensors.SelfTest" do
    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      assert {:fail, reason} = SelfTest.run(%{platform: :android, device: :emulator})
      assert reason =~ "mob_sensors_nif is not linked"
      assert reason =~ "nif_not_loaded"
      assert Mob.Plugin.SelfTest.result?({:fail, reason})
    end

    test "a sensor array passes, including the iOS simulator's empty one" do
      assert SelfTest.classify("[]") == :pass

      assert SelfTest.classify(
               ~s([{"type":6,"string_type":"android.sensor.pressure","name":"Goldfish Pressure"},) <>
                 ~s({"type":65537,"string_type":"com.motorola.sensor.x","name":null}])
             ) == :pass
    end

    test "an unwired Android bridge fails, naming what the bootstrap missed" do
      assert {:fail, "Kotlin MobSensorsBridge not registered" <> _} =
               SelfTest.classify({:error, :bridge_not_registered})

      assert {:fail, "MobSensorsBridge has no Activity" <> _} =
               SelfTest.classify({:error, :no_activity})

      assert SelfTest.classify({:error, :bridge_exception}) ==
               {:fail, "list/0 could not reach SensorManager: :bridge_exception"}
    end

    test "anything but a JSON array of sensors fails" do
      for answer <- [
            "",
            "not json",
            "{}",
            "[1]",
            ~s([{"name":"no type"}]),
            ~s([{"type":"6"}]),
            :ok
          ] do
        assert {:fail, "list/0 returned " <> _} = SelfTest.classify(answer), inspect(answer)
      end
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub against the server's calls, not app code.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the stub exports every NIF the server calls at the right arity" do
      exports = :mob_sensors_nif.module_info(:exports)

      for fa <- [list: 0, start: 4, stop: 1, stop_all: 0, steps: 3] do
        assert fa in exports, "#{inspect(fa)} missing from mob_sensors_nif exports"
      end
    end
  end

  describe "without a native layer (host build)" do
    test "list/0 is empty and reads, streams and steps are unavailable" do
      assert MobSensors.list() == []
      assert {:error, :unavailable} = MobSensors.read(:pressure)
      assert {:error, :unavailable} = MobSensors.start(:accelerometer)
      assert :ok = MobSensors.stop(:accelerometer)
      assert {:error, :unavailable} = MobSensors.steps(0, 1)
    end

    test "an unknown type is reported before the native layer is asked" do
      assert {:error, :unknown_type} = MobSensors.read(:bogus)
      assert {:error, :unknown_type} = MobSensors.start("")
      # Vendor string types must fit the native buffer and be valid UTF-8.
      assert {:error, :unknown_type} = MobSensors.read(String.duplicate("x", 256))
      assert {:error, :unknown_type} = MobSensors.read(<<0xFF, 0xFE>>)
    end
  end

  describe "option validation" do
    test "timeout_ms and interval_ms must be integers the platform can represent" do
      assert_raise ArgumentError, ~r/:timeout_ms/, fn ->
        MobSensors.read(:pressure, timeout_ms: 0)
      end

      assert_raise ArgumentError, ~r/:timeout_ms/, fn ->
        MobSensors.read(:pressure, timeout_ms: 4_294_967_296)
      end

      assert_raise ArgumentError, ~r/:interval_ms/, fn ->
        MobSensors.start(:pressure, interval_ms: 1.5)
      end

      # Microseconds must fit the native 32-bit period.
      assert_raise ArgumentError, ~r/:interval_ms/, fn ->
        MobSensors.start(:pressure, interval_ms: 2_147_484)
      end
    end

    test "steps/2 needs Unix milliseconds in order, within int64" do
      assert_raise ArgumentError, fn -> MobSensors.steps(2, 1) end
      assert_raise ArgumentError, fn -> MobSensors.steps(-1, 1) end
      assert_raise ArgumentError, fn -> MobSensors.steps(0, 9_223_372_036_854_775_808) end
      assert_raise ArgumentError, fn -> MobSensors.steps(~D[2026-01-01], 1) end
    end
  end

  describe "type mapping" do
    test "standard atoms map to Android Sensor.TYPE_* codes and back" do
      for {atom, code} <- [
            accelerometer: 1,
            magnetic_field: 2,
            gyroscope: 4,
            light: 5,
            pressure: 6,
            proximity: 8,
            gravity: 9,
            relative_humidity: 12,
            ambient_temperature: 13,
            significant_motion: 17,
            step_counter: 19,
            heart_rate: 21,
            hinge_angle: 36
          ] do
        assert Types.to_native(atom) == {:ok, {code, nil}}
        assert Types.from_native(code, "ignored") == atom
      end
    end

    test "vendor sensors are named by their string type, never a new atom" do
      assert Types.to_native("com.motorola.sensor.x") == {:ok, {-1, "com.motorola.sensor.x"}}
      assert Types.from_native(65_537, "com.motorola.sensor.x") == "com.motorola.sensor.x"
      assert Types.from_native(99_999, nil) == "unknown:99999"
    end

    test "units follow Android's SensorEvent" do
      assert Types.unit(:pressure) == "hPa"
      assert Types.unit(:light) == "lx"
      assert Types.unit(:proximity) == "cm"
      assert Types.unit(:accelerometer) == "m/s²"
      assert Types.unit(:rotation_vector) == nil
      assert Types.unit("com.motorola.sensor.x") == nil
    end
  end
end
