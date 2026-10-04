defmodule MobSensors.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children = [MobSensors.Server]
    Supervisor.start_link(children, strategy: :one_for_one, name: MobSensors.Supervisor)
  end
end
