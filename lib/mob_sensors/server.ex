defmodule MobSensors.Server do
  @moduledoc """
  Owns every native sensor listener and routes its readings to callers.

  The NIF sends readings to this process tagged with an integer handle (see
  `src/mob_sensors_nif.erl`); the server maps each handle to the caller and
  the type it asked for, forwards `{:mob_sensors, ...}` messages, and stops the
  native listener when a one-shot read completes or times out, when the
  caller calls `MobSensors.stop/1`, or when the caller dies (it monitors every
  caller). At init it stops any listener a previous incarnation left behind.

  Started by `MobSensors.Application`; use the `MobSensors` functions rather
  than calling it directly.
  """
  use GenServer

  alias MobSensors.Types

  require Logger

  # One-shot reads ask for SENSOR_DELAY_GAME (20 ms) so the first sample of a
  # continuous sensor arrives quickly; on-change sensors ignore the rate.
  @read_period_us 20_000

  # A steps/2 query CoreMotion never answers is reported as {:error, :timeout}.
  @default_steps_timeout_ms 10_000

  @type server :: GenServer.server()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec list(server()) :: [MobSensors.info()]
  def list(server), do: GenServer.call(server, :list)

  @doc false
  @spec read(server(), Types.t(), pos_integer()) :: :ok | {:error, :unavailable | :unknown_type}
  def read(server, type, timeout_ms) do
    with {:ok, native_type} <- Types.to_native(type) do
      GenServer.call(server, {:read, type, native_type, timeout_ms})
    end
  end

  @doc false
  @spec start(server(), Types.t(), pos_integer()) :: :ok | {:error, :unavailable | :unknown_type}
  def start(server, type, interval_ms) do
    with {:ok, native_type} <- Types.to_native(type) do
      GenServer.call(server, {:start, type, native_type, interval_ms * 1000})
    end
  end

  @doc false
  @spec stop(server(), Types.t()) :: :ok
  def stop(server, type), do: GenServer.call(server, {:stop, type})

  @doc false
  @spec steps(server(), integer(), integer()) ::
          :ok | {:error, :unavailable | :history_unavailable}
  def steps(server, from_ms, to_ms), do: GenServer.call(server, {:steps, from_ms, to_ms})

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    native = Keyword.get(opts, :native, :mob_sensors_nif)
    steps_timeout_ms = Keyword.get(opts, :steps_timeout_ms, @default_steps_timeout_ms)
    state = %{native: native, steps_timeout_ms: steps_timeout_ms, next: 1, subs: %{}}
    # Listeners whose owner died with a previous server would keep sending to
    # a dead pid forever; nothing else can stop them.
    _ = call_native(state, :stop_all, [])
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    infos =
      case call_native(state, :list, []) do
        json when is_binary(json) -> json |> JSON.decode!() |> Enum.map(&to_info/1)
        :native_unavailable -> []
      end

    {:reply, infos, state}
  end

  def handle_call({:read, type, native_type, timeout_ms}, {pid, _tag}, state) do
    begin(state, pid, type, native_type, @read_period_us, :read, timeout_ms)
  end

  def handle_call({:start, type, native_type, period_us}, {pid, _tag}, state) do
    state = stop_streams(state, pid, type)
    begin(state, pid, type, native_type, period_us, :stream, nil)
  end

  def handle_call({:stop, type}, {pid, _tag}, state) do
    {:reply, :ok, stop_streams(state, pid, type)}
  end

  def handle_call({:steps, from_ms, to_ms}, {pid, _tag}, state) do
    {handle, state} = next_handle(state)

    case call_native(state, :steps, [handle, from_ms, to_ms]) do
      :ok ->
        sub = %{
          pid: pid,
          ref: Process.monitor(pid),
          mode: :steps,
          from: from_ms,
          to: to_ms,
          timer: Process.send_after(self(), {:timeout, handle}, state.steps_timeout_ms)
        }

        {:reply, :ok, put_in(state.subs[handle], sub)}

      :history_unavailable ->
        {:reply, {:error, :history_unavailable}, state}

      unavailable when unavailable in [:unavailable, :native_unavailable] ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  @impl GenServer
  def handle_info({:mob_sensors_native, handle, :reading, values, ts, accuracy}, state) do
    case Map.fetch(state.subs, handle) do
      {:ok, %{mode: mode} = sub} when mode in [:read, :stream] ->
        reading = %{values: values, timestamp: ts, accuracy: accuracy}
        send(sub.pid, {:mob_sensors, :reading, sub.type, reading})
        {:noreply, if(mode == :read, do: finish(state, handle), else: state)}

      _late ->
        {:noreply, state}
    end
  end

  def handle_info({:mob_sensors_native, handle, :error, reason}, state) do
    case Map.fetch(state.subs, handle) do
      {:ok, %{mode: :steps, pid: pid}} ->
        send(pid, {:mob_sensors, :steps, {:error, reason}})
        {:noreply, finish(state, handle)}

      {:ok, sub} ->
        send(sub.pid, {:mob_sensors, :error, sub.type, reason})
        {:noreply, finish(state, handle)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:mob_sensors_native, handle, :steps, steps, distance, floors}, state) do
    case Map.fetch(state.subs, handle) do
      {:ok, %{mode: :steps} = sub} ->
        result = %{
          steps: steps,
          distance_m: to_float(distance),
          floors_ascended: floors,
          from: sub.from,
          to: sub.to
        }

        send(sub.pid, {:mob_sensors, :steps, {:ok, result}})
        {:noreply, finish(state, handle)}

      _late ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, handle}, state) do
    case Map.fetch(state.subs, handle) do
      {:ok, %{mode: :read} = sub} ->
        send(sub.pid, {:mob_sensors, :error, sub.type, :timeout})
        {:noreply, finish(state, handle)}

      {:ok, %{mode: :steps} = sub} ->
        send(sub.pid, {:mob_sensors, :steps, {:error, :timeout}})
        {:noreply, finish(state, handle)}

      _done ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    handles = for {handle, %{ref: ^ref}} <- state.subs, do: handle
    {:noreply, Enum.reduce(handles, state, &finish(&2, &1))}
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp begin(state, pid, type, {code, string_type}, period_us, mode, timeout_ms) do
    {handle, state} = next_handle(state)

    case call_native(state, :start, [handle, code, string_type, period_us]) do
      :ok ->
        timer = timeout_ms && Process.send_after(self(), {:timeout, handle}, timeout_ms)
        sub = %{pid: pid, ref: Process.monitor(pid), type: type, mode: mode, timer: timer}
        {:reply, :ok, put_in(state.subs[handle], sub)}

      # Nothing was registered; the missing grant is reported the same way an
      # asynchronous denial is, so callers handle one shape.
      :permission ->
        send(pid, {:mob_sensors, :error, type, :permission})
        {:reply, :ok, state}

      unavailable when unavailable in [:unavailable, :native_unavailable] ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  defp stop_streams(state, pid, type) do
    handles =
      for {handle, %{mode: :stream, pid: ^pid, type: ^type}} <- state.subs, do: handle

    Enum.reduce(handles, state, &finish(&2, &1))
  end

  # Drops a subscription: stops its native listener (idempotent natively, so
  # a listener that already reported an error is fine), its timer and monitor.
  defp finish(state, handle) do
    {sub, subs} = Map.pop(state.subs, handle)

    if sub do
      if sub.mode != :steps, do: call_native(state, :stop, [handle])
      if sub[:timer], do: Process.cancel_timer(sub.timer)
      Process.demonitor(sub.ref, [:flush])
    end

    %{state | subs: subs}
  end

  defp next_handle(state), do: {state.next, %{state | next: state.next + 1}}

  # A host build (and `mix test`) has no NIF linked, and a NIF rejects
  # arguments it can't represent with badarg: report both as a value each
  # caller maps (empty list, :unavailable) so one bad call can't take down
  # every other caller's listeners with the server.
  defp call_native(state, fun, args) do
    apply(state.native, fun, args)
  rescue
    error in ErlangError ->
      case error do
        %ErlangError{original: :nif_not_loaded} -> :native_unavailable
        _other -> reraise error, __STACKTRACE__
      end

    error in ArgumentError ->
      Logger.warning(
        "mob_sensors: #{fun}/#{length(args)} rejected #{inspect(args)}: " <>
          Exception.message(error)
      )

      :native_unavailable
  end

  defp to_info(entry) do
    type = Types.from_native(entry["type"], entry["string_type"])

    %{
      type: type,
      name: entry["name"],
      vendor: entry["vendor"],
      unit: Types.unit(type),
      max_range: to_float(entry["max_range"]),
      resolution: to_float(entry["resolution"]),
      wake_up: entry["wake_up"]
    }
  end

  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(nil), do: nil
end
