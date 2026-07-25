defmodule SidechannelSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :sidechannel_sim,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SidechannelSim.Application, []}
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.0"},
      {:jason, "~> 1.4"} # Binary Ninja (Python) へ JSON で結果を返すため
    ]
  end

  defp releases do
    [
      sidechannel_sim: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            windows: [os: :windows, cpu: :x86_64],
            macos: [os: :darwin, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
