defmodule MobMidi.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_midi"

  def project do
    [
      app: :mob_midi,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      description:
        "MIDI in + out (USB / BLE) for Mob apps — CoreMIDI on iOS, android.media.midi on Android",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md"]
      ],
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    [
      {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test]},
      {:mob, "~> 0.7"},
      {:mob_dev, "~> 0.6", only: [:dev, :test], runtime: false},
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
      # Native sources + manifest must ship — the host's native build compiles
      # them from deps/mob_midi/priv.
      files: ~w(lib src priv mix.exs README* CHANGELOG*)
    ]
  end
end
