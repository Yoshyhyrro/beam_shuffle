defmodule SidechannelSim do
  @moduledoc """
  Side-channel vulnerability simulator entrypoint.
  """

  # Output result as JSON for Binary Ninja plugin integration
  def main(args) do
    {opts, _args, _} = OptionParser.parse!(args,
      strict: [steps: :integer, workers: :integer],
      aliases: [s: :steps, w: :workers]
    )

    steps = opts[:steps] || 1_000_000
    workers = opts[:workers] || 4

    # Run quantum-walk/interference engine on :atomics
    results = SidechannelSim.Engine.run(steps, workers)

    # Format result as JSON for easy parsing in Python
    %{
      status: "ok",
      steps: steps,
      leakage_probabilities: results
    }
    |> Jason.encode!()
    |> IO.puts()
  end
end
