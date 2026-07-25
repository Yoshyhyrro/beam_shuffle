defmodule QuantumSimulation.HeptadecagonShuffleProduct do
  @moduledoc """
  Implements the shuffle product on a 17-cycle using `:atomics` for complex amplitudes
  and `:counters` for probability distribution tracking.

  Mathematical properties:
  - Group: C₁₇ (cyclic group of order 17)
  - Shuffle product: Convolution on Z₁₇
  - Quantum walk: X = S · (I ⊗ C) across 17 distinct positions
  """

  # Imports the Erlang math module functions to omit the `:math.` prefix.
  import :math, only: [sqrt: 1, log: 1, pi: 0, cos: 1, sin: 1]

  @group_order 17
  @scale 10_000  # Fixed-point precision multiplier for complex amplitudes

  # Memory layout for :atomics (1-based indexing):
  # 34 elements (17 complex pairs) + 1 norm + 1 phase = 36 total elements
  @amp_offset 1
  @norm_index 35
  @phase_index 36
  @total_atomics 36

  # Memory layout for :counters (1-based indexing): 17 basis states + 1 total aggregate count
  @counter_total 17
  @total_counters 18

  # ===========================================================================
  # 1. STATE INITIALIZATION
  # ===========================================================================

  @doc """
  Initializes a novel 17-gon quantum state, defaulting all amplitudes to zero.
  """
  def new_quantum_state do
    atomics = :atomics.new(@total_atomics, [])

    # Initialize strictly to the |0⟩ state (Erlang :atomics is 1-based)
    :atomics.put(atomics, @amp_offset + 0, @scale)      # Real part of |0⟩ = 1.0 (Index 1)
    :atomics.put(atomics, @amp_offset + 1, 0)           # Imaginary part of |0⟩ = 0.0 (Index 2)

    # Ensure all subsequent amplitudes remain zero (Indices 3 to 34)
    for i <- (@amp_offset + 2)..(@norm_index - 1) do
      :atomics.put(atomics, i, 0)
    end

    # Establish the normalization constant (Index 35)
    :atomics.put(atomics, @norm_index, @scale * @scale)

    # Reset the global phase (Index 36)
    :atomics.put(atomics, @phase_index, 0)

    atomics
  end

  @doc """
  Allocates a concurrent counter array strictly for measurement statistics.
  Note: Erlang's `:counters` utilizes 1-based indexing and supports [:write_concurrency].
  """
  def new_counters do
    :counters.new(@total_counters, [:write_concurrency])
  end

  # ===========================================================================
  # 2. AMPLITUDE ACCESSORS
  # ===========================================================================

  @doc """
  Retrieves the complex amplitude associated with the basis state |k⟩ as a {real, imag} tuple.
  """
  def get_amplitude(atomics, k) when k in 0..(@group_order - 1) do
    idx_real = @amp_offset + 2 * k
    idx_imag = @amp_offset + 2 * k + 1
    {
      :atomics.get(atomics, idx_real) / @scale,
      :atomics.get(atomics, idx_imag) / @scale
    }
  end

  @doc """
  Atomically dictates the complex amplitude for basis state |k⟩.
  Returns `:ok` upon successful Compare-And-Swap (CAS), or `:error` upon contention failure.
  """
  def set_amplitude(atomics, k, real, imag) when k in 0..(@group_order - 1) do
    idx_real = @amp_offset + 2 * k
    idx_imag = @amp_offset + 2 * k + 1

    real_scaled = round(real * @scale)
    imag_scaled = round(imag * @scale)

    # Leverage CAS to guarantee atomic consistency
    with :ok <- :atomics.compare_exchange(
           atomics, idx_real,
           :atomics.get(atomics, idx_real),
           real_scaled
         ),
         :ok <- :atomics.compare_exchange(
           atomics, idx_imag,
           :atomics.get(atomics, idx_imag),
           imag_scaled
         ) do
      update_normalization(atomics)
      :ok
    else
      _ -> :error
    end
  end

  # Internal function to maintain the normalization factor
  defp update_normalization(atomics) do
    total_prob =
      Enum.reduce(0..(@group_order - 1), 0.0, fn k, acc ->
        {r, i} = get_amplitude(atomics, k)
        acc + r * r + i * i
      end)

    :atomics.put(atomics, @norm_index, round(total_prob * @scale * @scale))
  end

  # ===========================================================================
  # 3. SHUFFLE PRODUCT OPERATIONS
  # ===========================================================================

  @doc """
  Executes the shuffle product (convolution) mapping the current state onto itself.
  This functionally generates the two-step quantum walk distribution.
  """
  def self_shuffle(atomics) do
    # Snapshot the current amplitudes to mitigate race conditions
    amps =
      for k <- 0..(@group_order - 1), into: %{} do
        {k, get_amplitude(atomics, k)}
      end

    # Calculate convolution: new_amp(k) = Σ_{i} amp(i) * amp((k-i) mod 17)
    new_amps =
      for k <- 0..(@group_order - 1) do
        sum =
          Enum.reduce(0..(@group_order - 1), {0.0, 0.0}, fn i, {acc_r, acc_i} ->
            {r1, i1} = amps[i]
            j = rem(k - i + @group_order, @group_order)
            {r2, i2} = amps[j]

            # Complex scalar multiplication: (r1 + i i1) * (r2 + i i2)
            {
              acc_r + (r1 * r2 - i1 * i2),
              acc_i + (r1 * i2 + i1 * r2)
            }
          end)

        {k, sum}
      end

    # Atomically overwrite all amplitudes
    Enum.reduce_while(new_amps, :ok, fn {k, {r, i}}, _acc ->
      case set_amplitude(atomics, k, r, i) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Computes the shuffle product mapping over two discrete quantum states.
  Returns a freshly allocated atomic array encompassing the resultant state.
  """
  def shuffle_product(atomics_a, atomics_b) do
    amps_a = for k <- 0..(@group_order - 1), into: %{}, do: {k, get_amplitude(atomics_a, k)}
    amps_b = for k <- 0..(@group_order - 1), into: %{}, do: {k, get_amplitude(atomics_b, k)}

    result = new_quantum_state()

    for k <- 0..(@group_order - 1) do
      sum =
        Enum.reduce(0..(@group_order - 1), {0.0, 0.0}, fn i, {acc_r, acc_i} ->
          {r1, i1} = amps_a[i]
          j = rem(k - i + @group_order, @group_order)
          {r2, i2} = amps_b[j]

          {
            acc_r + (r1 * r2 - i1 * i2),
            acc_i + (r1 * i2 + i1 * r2)
          }
        end)

      set_amplitude(result, k, elem(sum, 0), elem(sum, 1))
    end

    result
  end

  # ===========================================================================
  # 4. QUANTUM WALK ON 17-GON
  # ===========================================================================

  @doc """
  Executes a singular discrete-time quantum walk iteration across the 17-gon structure.
  Integrates the Hadamard coin and conditional shift operators.
  """
  def quantum_walk_step(atomics, counters \\ nil) do
    amps = for k <- 0..(@group_order - 1), into: %{}, do: {k, get_amplitude(atomics, k)}

    # Apply the Hadamard coin operator onto each spatial node
    coin_amps =
      for k <- 0..(@group_order - 1) do
        {r, i} = amps[k]
        sqrt2 = sqrt(2.0)
        {
          k,
          {r / sqrt2, i / sqrt2},  # Sub-component mapped to |0⟩
          {r / sqrt2, i / sqrt2}   # Sub-component mapped to |1⟩
        }
      end

    # Apply the conditional shift operator S
    new_amps =
      Enum.reduce(coin_amps, %{}, fn {k, {r0, i0}, {r1, i1}}, acc ->
        k_minus = rem(k - 1 + @group_order, @group_order)
        acc =
          Map.update(acc, k_minus, {r0, i0}, fn {ar, ai} ->
            {ar + r0, ai + i0}
          end)

        k_plus = rem(k + 1, @group_order)
        Map.update(acc, k_plus, {r1, i1}, fn {ar, ai} ->
          {ar + r1, ai + i1}
        end)
      end)

    # Enforce unitary normalization post-shift
    total_prob =
      Enum.reduce(new_amps, 0.0, fn {_, {r, i}}, acc ->
        acc + r * r + i * i
      end)

    norm_factor = 1.0 / sqrt(total_prob)

    Enum.each(new_amps, fn {k, {r, i}} ->
      set_amplitude(atomics, k, r * norm_factor, i * norm_factor)
    end)

    # Persist measurement statistics when a counter telemetry module is injected
    if counters do
      probs = get_probabilities(atomics)
      measure_and_record(atomics, counters, probs)
    end

    {:ok, :walk_step_completed}
  end

  # ===========================================================================
  # 5. MEASUREMENT AND STATISTICS
  # ===========================================================================

  @doc """
  Executes a projective measurement collapsed onto the position basis via the Born rule.
  """
  def measure(atomics) do
    probs = get_probabilities(atomics)
    rnd = :rand.uniform()

    measured_state =
      Enum.reduce_while(0..(@group_order - 1), 0.0, fn k, acc ->
        new_acc = acc + Map.get(probs, k, 0.0)
        if rnd <= new_acc do
          {:halt, k}
        else
          {:cont, new_acc}
        end
      end)

    # Collapse the superposition strictly to the measured eigenstate
    for k <- 0..(@group_order - 1) do
      if k == measured_state do
        set_amplitude(atomics, k, 1.0, 0.0)
      else
        set_amplitude(atomics, k, 0.0, 0.0)
      end
    end

    measured_state
  end

  @doc """
  Derives the classical probability distribution strictly from the underlying atomic amplitudes.
  """
  def get_probabilities(atomics) do
    total =
      Enum.reduce(0..(@group_order - 1), 0.0, fn k, acc ->
        {r, i} = get_amplitude(atomics, k)
        acc + r * r + i * i
      end)

    for k <- 0..(@group_order - 1), into: %{} do
      {r, i} = get_amplitude(atomics, k)
      {k, (r * r + i * i) / total}
    end
  end

  defp measure_and_record(atomics, counters, _probs) do
    state = measure(atomics)
    # Erlang :counters arrays strictly require 1-based indexing
    :counters.add(counters, state + 1, 1)
    :counters.add(counters, @counter_total + 1, 1)
    state
  end

  # ===========================================================================
  # 6. ENTANGLEMENT AND SHUFFLE INVARIANTS
  # ===========================================================================

  @doc """
  Quantifies the Shannon entropy bounded by the derived probability distribution.
  """
  def shuffle_entropy(atomics) do
    probs = get_probabilities(atomics)

    probs
    |> Map.values()
    |> Enum.filter(&(&1 > 0))
    |> Enum.map(fn p -> -p * log(p) end)
    |> Enum.sum()
  end

  @doc """
  Applies the Discrete Fourier Transform (DFT) mapping over the shuffle product topology.
  For C₁₇, this inherently diagonalizes the convolution operator matrix.
  """
  def fourier_eigenvalues(atomics) do
    probs = get_probabilities(atomics)

    for m <- 0..(@group_order - 1) do
      # λ_m = Σ_{k=0}^{16} P(k) * ω^{mk}  | where ω = exp(2πi/17)
      Enum.reduce(0..(@group_order - 1), {0.0, 0.0}, fn k, {acc_r, acc_i} ->
        theta = 2 * pi() * m * k / @group_order
        p = Map.get(probs, k, 0.0)
        {
          acc_r + p * cos(theta),
          acc_i + p * sin(theta)
        }
      end)
    end
  end

  @doc """
  Evaluates whether the topological shuffle product converges idiopathically (idempotency).
  """
  def idempotent?(atomics, tolerance \\ 1.0e-6) do
    shuffled = self_shuffle_copy(atomics)

    # Validates matrix congruence within defined floating-point error bounds
    Enum.all?(0..(@group_order - 1), fn k ->
      {r1, i1} = get_amplitude(atomics, k)
      {r2, i2} = get_amplitude(shuffled, k)

      abs(r1 - r2) <= tolerance and abs(i1 - i2) <= tolerance
    end)
  end

  defp self_shuffle_copy(atomics) do
    result = new_quantum_state()
    amps = for k <- 0..(@group_order - 1), into: %{}, do: {k, get_amplitude(atomics, k)}

    for k <- 0..(@group_order - 1) do
      sum =
        Enum.reduce(0..(@group_order - 1), {0.0, 0.0}, fn i, {acc_r, acc_i} ->
          {r1, i1} = amps[i]
          j = rem(k - i + @group_order, @group_order)
          {r2, i2} = amps[j]

          {
            acc_r + (r1 * r2 - i1 * i2),
            acc_i + (r1 * i2 + i1 * r2)
          }
        end)

      set_amplitude(result, k, elem(sum, 0), elem(sum, 1))
    end

    result
  end

  # ===========================================================================
  # 7. CONCURRENT SHUFFLE WITH COUNTERS
  # ===========================================================================

  @doc """
  Bootstraps and orchestrates the parallel shuffle engine simulation across the 17-gon topology.
  """
  def concurrent_shuffle_simulation(num_steps, num_workers) do
    atomics = new_quantum_state()
    counters = new_counters()

    # Distribute the initial state into a uniform superposition manifold
    init_amp = 1.0 / sqrt(@group_order)
    for k <- 0..(@group_order - 1) do
      set_amplitude(atomics, k, init_amp, 0.0)
    end

    # Bootstrap the concurrency pool mapping independent random walks
    workers =
      for _ <- 1..num_workers do
        spawn(fn ->
          :rand.seed(:exsss, :os.timestamp())

          Enum.each(1..num_steps, fn _ ->
            quantum_walk_step(atomics, counters)
            Process.sleep(:rand.uniform(10))
          end)
        end)
      end

    # Block main thread until worker pipeline convergence
    Enum.each(workers, fn pid ->
      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end
    end)

    # Aggregate telemetry payloads post-execution
    probs = get_probabilities(atomics)
    entropy = shuffle_entropy(atomics)
    eigenvals = fourier_eigenvalues(atomics)

    total_measurements = :counters.get(counters, @counter_total + 1)
    measured_probs =
      for k <- 0..(@group_order - 1), into: %{} do
        count = :counters.get(counters, k + 1)
        {k, if(total_measurements > 0, do: count / total_measurements, else: 0.0)}
      end

    %{
      quantum_probabilities: probs,
      measured_probabilities: measured_probs,
      total_measurements: total_measurements,
      entropy: entropy,
      fourier_eigenvalues: eigenvals,
      step_count: num_steps * num_workers,
      workers: num_workers
    }
  end
end

# ===========================================================================
# EXECUTION SCRIPT FOR idea.exs
# ===========================================================================
alias QuantumSimulation.HeptadecagonShuffleProduct, as: ShuffleProduct

IO.puts("=== Initializing Heptadecagon Shuffle Product Simulation ===")

num_steps = 10
num_workers = 4

IO.puts("Dispatching #{num_workers} concurrent workers for #{num_steps} simulation steps...")
result = ShuffleProduct.concurrent_shuffle_simulation(num_steps, num_workers)

IO.puts("\n=== Simulation Telemetry ===")
IO.puts("Total Born Rule Measurements : #{result.total_measurements}")
IO.puts("Final Shannon Entropy        : #{Float.round(result.entropy, 5)}")

IO.puts("\n=== Measured Probability Distribution ===")
Enum.each(result.measured_probabilities, fn {state, prob} ->
  formatted_prob = :erlang.float_to_binary(prob, decimals: 4)
  state_str = String.pad_leading(Integer.to_string(state), 2)
  IO.puts("State |#{state_str}> : #{formatted_prob}")
end)

IO.puts("\nSimulation successfully concluded.")
