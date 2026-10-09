defmodule MobSensors.ServerTest do
  # Not async: the fake native layer reports its calls to one registered name.
  use ExUnit.Case, async: false

  alias MobSensors.Server

  @observer :mob_sensors_fake_observer

  # Stands in for :mob_sensors_nif. Runs inside the server process (as the
  # real NIF does), so `self()` is the server and readings it sends back take
  # the same path native ones do. Every call is reported to the test.
  defmodule FakeNative do
    @magnetic_field 2
    @pressure 6
    @proximity 8
    @step_counter 19

    def list do
      report(:list, [])

      JSON.encode!([
        %{
          type: 6,
          string_type: "android.sensor.pressure",
          name: "Goldfish Pressure",
          vendor: "The Android Open Source Project",
          max_range: 1100,
          resolution: 0.005,
          wake_up: false
        },
        %{
          type: 65_537,
          string_type: "com.motorola.sensor.x",
          name: "Moto X",
          vendor: nil,
          max_range: nil,
          resolution: 1.0,
          wake_up: true
        },
        %{type: 22, string_type: "android.sensor.tilt_detector", name: "Tilt"}
      ])
    end

    def start(handle, code, string_type, period_us) do
      report(:start, [handle, code, string_type, period_us])

      case {code, string_type} do
        {@pressure, nil} ->
          send(self(), {:mob_sensors_native, handle, :reading, [1013.25], 1_700_000_000_000, 3})
          :ok

        {@proximity, nil} ->
          :ok

        {@step_counter, nil} ->
          :permission

        {-1, "com.motorola.sensor.x"} ->
          :ok

        # What a NIF does with an argument it can't represent.
        {@magnetic_field, nil} ->
          raise ArgumentError, "argument error"

        _other ->
          :unavailable
      end
    end

    def stop(handle), do: report(:stop, [handle])
    def stop_all, do: report(:stop_all, [])

    # A query CoreMotion never answers.
    def steps(handle, 13 = from, to), do: report(:steps, [handle, from, to])

    def steps(handle, from, to) do
      report(:steps, [handle, from, to])
      send(self(), {:mob_sensors_native, handle, :steps, 4321, 3010.5, nil})
      :ok
    end

    defp report(fun, args) do
      send(:mob_sensors_fake_observer, {:native, fun, args})
      :ok
    end
  end

  # The Android NIF in a host whose bootstrap never wired the bridge.
  defmodule UnwiredNative do
    def list, do: {:error, :bridge_not_registered}
    def stop_all, do: :ok
  end

  setup do
    Process.register(self(), @observer)
    server = start_supervised!({Server, name: nil, native: FakeNative, steps_timeout_ms: 50})
    assert_receive {:native, :stop_all, []}
    %{server: server}
  end

  test "list/0 maps native entries to info maps", %{server: server} do
    assert [pressure, vendor, hidden] = Server.list(server)

    assert pressure == %{
             type: :pressure,
             name: "Goldfish Pressure",
             vendor: "The Android Open Source Project",
             unit: "hPa",
             max_range: 1100.0,
             resolution: 0.005,
             wake_up: false
           }

    assert %{type: "com.motorola.sensor.x", unit: nil, vendor: nil, max_range: nil} = vendor
    # A hidden Android type without a public constant keeps its string type.
    assert %{type: "android.sensor.tilt_detector", wake_up: nil} = hidden
  end

  test "list/0 is [] and logs the reason when the Android bridge is not wired" do
    server = start_supervised!({Server, name: nil, native: UnwiredNative}, id: :unwired)

    log = ExUnit.CaptureLog.capture_log(fn -> assert Server.list(server) == [] end)
    assert log =~ "list/0 could not reach SensorManager: :bridge_not_registered"
  end

  describe "read" do
    test "delivers one reading tagged with the requested type, then stops the listener",
         %{server: server} do
      assert :ok = Server.read(server, :pressure, 1_000)
      assert_receive {:native, :start, [handle, 6, nil, 20_000]}

      assert_receive {:mob_sensors, :reading, :pressure,
                      %{values: [1013.25], timestamp: 1_700_000_000_000, accuracy: 3}}

      assert_receive {:native, :stop, [^handle]}
    end

    test "a vendor string type is passed through and reported back verbatim",
         %{server: server} do
      assert :ok = Server.read(server, "com.motorola.sensor.x", 1_000)
      assert_receive {:native, :start, [handle, -1, "com.motorola.sensor.x", _period]}
      send(server, {:mob_sensors_native, handle, :reading, [1.0, 2.0], 5, nil})

      assert_receive {:mob_sensors, :reading, "com.motorola.sensor.x",
                      %{values: [1.0, 2.0], timestamp: 5, accuracy: nil}}
    end

    test "times out with an error message and stops the listener", %{server: server} do
      assert :ok = Server.read(server, :proximity, 30)
      assert_receive {:native, :start, [handle, 8, nil, _period]}
      assert_receive {:mob_sensors, :error, :proximity, :timeout}, 500
      assert_receive {:native, :stop, [^handle]}
    end

    test "a missing grant is an error message, not a return value", %{server: server} do
      assert :ok = Server.read(server, :step_counter, 1_000)
      assert_receive {:mob_sensors, :error, :step_counter, :permission}
    end

    test "an asynchronous native error ends the read", %{server: server} do
      assert :ok = Server.read(server, :proximity, 1_000)
      assert_receive {:native, :start, [handle, 8, nil, _period]}
      send(server, {:mob_sensors_native, handle, :error, "sensor went away"})
      assert_receive {:mob_sensors, :error, :proximity, "sensor went away"}
      assert_receive {:native, :stop, [^handle]}
    end

    test "a sensor the device lacks is {:error, :unavailable}", %{server: server} do
      assert {:error, :unavailable} = Server.read(server, :light, 1_000)
    end

    test "an unknown type never reaches the native layer", %{server: server} do
      assert {:error, :unknown_type} = Server.read(server, :not_a_sensor, 1_000)
      assert {:error, :unknown_type} = Server.read(server, 42, 1_000)
      refute_received {:native, :start, _args}
    end
  end

  describe "streaming" do
    test "forwards every reading until stop/2, then ignores late ones", %{server: server} do
      assert :ok = Server.start(server, :proximity, 200)
      assert_receive {:native, :start, [handle, 8, nil, 200_000]}

      send(server, {:mob_sensors_native, handle, :reading, [0.0], 1, 0})
      send(server, {:mob_sensors_native, handle, :reading, [5.0], 2, 0})
      assert_receive {:mob_sensors, :reading, :proximity, %{values: [+0.0]}}
      assert_receive {:mob_sensors, :reading, :proximity, %{values: [5.0]}}

      assert :ok = Server.stop(server, :proximity)
      assert_receive {:native, :stop, [^handle]}

      send(server, {:mob_sensors_native, handle, :reading, [0.0], 3, 0})
      refute_receive {:mob_sensors, :reading, :proximity, _late}, 50
    end

    test "starting a type the caller already streams replaces the old listener",
         %{server: server} do
      assert :ok = Server.start(server, :proximity, 200)
      assert_receive {:native, :start, [first, 8, nil, _period]}
      assert :ok = Server.start(server, :proximity, 100)
      assert_receive {:native, :stop, [^first]}
      assert_receive {:native, :start, [second, 8, nil, 100_000]}
      assert second != first
    end

    test "stop/2 of a type that isn't streaming is a no-op", %{server: server} do
      assert :ok = Server.stop(server, :pressure)
      refute_receive {:native, :stop, _args}, 50
    end

    test "a caller that dies has its listeners stopped", %{server: server} do
      test_pid = self()

      caller =
        spawn(fn ->
          :ok = Server.start(server, :proximity, 200)
          send(test_pid, :started)
          receive(do: (:never -> :ok))
        end)

      assert_receive :started
      assert_receive {:native, :start, [handle, 8, nil, _period]}
      Process.exit(caller, :kill)
      assert_receive {:native, :stop, [^handle]}
    end
  end

  describe "steps" do
    test "delivers the native result with the queried range", %{server: server} do
      assert :ok = Server.steps(server, 1_000, 2_000)
      assert_receive {:native, :steps, [_handle, 1_000, 2_000]}

      assert_receive {:mob_sensors, :steps,
                      {:ok,
                       %{
                         steps: 4321,
                         distance_m: 3010.5,
                         floors_ascended: nil,
                         from: 1_000,
                         to: 2_000
                       }}}
    end

    test "a query that is never answered times out", %{server: server} do
      assert :ok = Server.steps(server, 13, 2_000)
      assert_receive {:mob_sensors, :steps, {:error, :timeout}}, 500
    end
  end

  @tag :capture_log
  test "a NIF badarg is an :unavailable reply and leaves other streams running",
       %{server: server} do
    assert :ok = Server.start(server, :proximity, 200)
    assert_receive {:native, :start, [handle, 8, nil, _period]}

    assert {:error, :unavailable} = Server.read(server, :magnetic_field, 1_000)

    send(server, {:mob_sensors_native, handle, :reading, [5.0], 1, 0})
    assert_receive {:mob_sensors, :reading, :proximity, %{values: [5.0]}}
  end
end
