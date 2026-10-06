defmodule MobSensors.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_sensors"

  def project do
    [
      app: :mob_sensors,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      aliases: aliases(),
      description:
        "Every phone sensor for Mob apps: list the device's sensors, read one sample, " <>
          "stream readings, and query step history (Android + iOS)",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MobSensors.Application, []}
    ]
  end

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push
    # and the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    # mob ~> 0.9.6: plugin OTP applications are started on device from that
    # release on (Mob.Plugins.start/0), and MobSensors.Server lives in this
    # plugin's supervision tree. :mob_dev is test-only (the manifest tests run
    # the real pre-publish validator) and never ships.
    [
      {:mob, "~> 0.9.6"},
      {:mob_dev, "~> 0.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The native sources + manifest must ship in the package — the host's
      # native build compiles them from deps/<plugin>/priv.
      files: ~w(lib src priv mix.exs README* CHANGELOG*)
    ]
  end
end
