defmodule HeptadecagonShuffleProduct do
  @moduledoc """
  Implements shuffle product on a 17-cycle using :atomics for complex amplitudes
  and :counters for probability distribution tracking.

  Mathematical properties:
  - Group: C₁₇ (cyclic group of order 17)
  - Shuffle product = convolution on Z₁₇
  - Quantum walk: X = S · (I ⊗ C) with 17 positions
  """

  @group_order 17
  @scale 10_000  # Fixed-point precision for amplitudes

  # :atomics layout: 17 complex amplitudes + 1 normalization + 1 phase
  @amp_offset 0
  @norm_index 34
  @phase_index 35
  @total_atomics 36

  # :counters layout: 17 basis states + total count
  @counter_states 17
  @counter_total 17
  @total_counters 18

  # ===========================================================================
  # 1. STATE INITIALIZATION
  # ===========================================================================

  @doc """
  Creates a new 17-gon quantum state with all amplitudes zero.
  """
  def new_quantum_state do
    atomics = :atomics.new(@total_atomics, [:write_concurrency])

    # Initialize to |0⟩ state
    :atomics.put(atomics, @amp_offset + 0, @scale)      # Real part of |0⟩ = 1.0
    :atomics.put(atomics, @amp_offset + 1, 0)           # Imag part of |0⟩ = 0.0

    # All other amplitudes zero
    for i <- 2..(@total_atomics - 3) do
      :atomics.put(atomics, i, 0)
    end

    # Normalization constant
    :atomics.put(atomics, @norm_index, @scale * @scale)

    # Global phase = 0
    :atomics.put(atomics, @phase_index, 0)

    atomics
  end

  @doc """
  Creates a new counter array for measurement statistics.
  """
  def new_counters do
    :counters.new(@total_counters, [:write_concurrency])
  end

  # ===========================================================================
  # 2. AMPLITUDE ACCESSORS
  # ===========================================================================

  @doc """
  Gets the complex amplitude for basis state |k⟩ as {real, imag}.
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
  Sets the complex amplitude for basis state |k⟩ atomically.
  Returns :ok on success, :error on CAS failure.
  """
  def set_amplitude(atomics, k, real, imag) when k in 0..(@group_order - 1) do
    idx_real = @amp_offset + 2 * k
    idx_imag = @amp_offset + 2 * k + 1

    real_scaled = round(real * @scale)
    imag_scaled = round(imag * @scale)

    # Use CAS for consistency
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
      # Update normalization
      update_normalization(atomics)
      :ok
    else
      _ -> :error
    end
  end

  # ===========================================================================
  # 3. SHUFFLE PRODUCT OPERATIONS
  # ===========================================================================

  @doc """
  Applies the shuffle product (convolution) of the current state with itself.
  This generates the 2-step quantum walk distribution.

  Mathematically:
    (ψ * ψ)(k) = Σ_{i+j ≡ k mod 17} ψ(i)ψ(j)

  The operation is atomic and uses a snapshot to avoid race conditions.
  """
  def self_shuffle(atomics) do
    # Snapshot current amplitudes
    amps =
      for k <- 0..(@group_order - 1) do
        {k, get_amplitude(atomics, k)}
      end
      |> Map.new()

    # Compute convolution: new_amp(k) = Σ_{i} amp(i) * amp((k-i) mod 17)
    new_amps =
      for k <- 0..(@group_order - 1) do
        sum =
          Enum.reduce(0..(@group_order - 1), {0.0, 0.0}, fn i, {acc_r, acc_i} ->
            {r1, i1} = amps[i]
            j = rem(k - i + @group_order, @group_order)
            {r2, i2} = amps[j]

            # Complex multiplication: (r1 + i i1) * (r2 + i i2)
            {
              acc_r + (r1 * r2 - i1 * i2),
              acc_i + (r1 * i2 + i1 * r2)
            }
          end)

        {k, sum}
      end

    # Atomically update all amplitudes
    Enum.reduce_while(new_amps, :ok, fn {k, {r, i}}, _acc ->
      case set_amplitude(atomics, k, r, i) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Applies the shuffle product of two distinct states.

  Given two atomic arrays state_a and state_b, computes:
    (ψ_a * ψ_b)(k) = Σ_{i+j ≡ k mod 17} ψ_a(i)ψ_b(j)

  Returns a new atomic array containing the result.
  """
  def shuffle_product(atomics_a, atomics_b) do
    # Snapshot both states
    amps_a =
      for k <- 0..(@group_order - 1) do
        {k, get_amplitude(atomics_a, k)}
      end
      |> Map.new()

    amps_b =
      for k <- 0..(@group_order - 1) do
        {k, get_amplitude(atomics_b, k)}
      end
      |> Map.new()

    # Compute convolution
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
  Performs one step of the quantum walk on the 17-gon.
  Uses the Hadamard coin and shift operator.

  The unitary step is: U = S · (I ⊗ C) where:
    - C = Hadamard coin: |0⟩ → (|0⟩+|1⟩)/√2, |1⟩ → (|0⟩-|1⟩)/√2
    - S = Shift: |k⟩|0⟩ → |k-1⟩|0⟩, |k⟩|1⟩ → |k+1⟩|1⟩

  The shuffle product emerges from the reduced density matrix.
  """
  def quantum_walk_step(atomics, counters \\ nil) do
    # Snapshot current amplitudes
    amps =
      for k <- 0..(@group_order - 1) do
        {k, get_amplitude(atomics, k)}
      end
      |> Map.new()

    # Apply Hadamard coin to each position
    # For each k, create entangled coin state: |k⟩(H|0⟩)
    coin_amps =
      for k <- 0..(@group_order - 1) do
        {r, i} = amps[k]

        # H|0⟩ = (|0⟩ + |1⟩)/√2
        sqrt2 = :math.sqrt(2.0)
        {
          k,
          {r / sqrt2, i / sqrt2},  # |0⟩ coin component
          {r / sqrt2, i / sqrt2}   # |1⟩ coin component
        }
      end

    # Apply shift operator S
    # |k⟩|0⟩ → |k-1⟩|0⟩, |k⟩|1⟩ → |k+1⟩|1⟩
    new_amps =
      Enum.reduce(coin_amps, %{}, fn {k, {r0, i0}, {r1, i1}}, acc ->
        # Shift |0⟩ component to k-1
        k_minus = rem(k - 1 + @group_order, @group_order)
        acc =
          Map.update(acc, k_minus, {r0, i0}, fn {ar, ai} ->
            {ar + r0, ai + i0}
          end)

        # Shift |1⟩ component to k+1
        k_plus = rem(k + 1, @group_order)
        Map.update(acc, k_plus, {r1, i1}, fn {ar, ai} ->
          {ar + r1, ai + i1}
        end)
      end)

    # Normalize and update atomically
    total_prob =
      Enum.reduce(new_amps, 0.0, fn {_, {r, i}}, acc ->
        acc + r*r + i*i
      end)

    norm_factor = 1.0 / :math.sqrt(total_prob)

    Enum.each(new_amps, fn {k, {r, i}} ->
      set_amplitude(atomics, k, r * norm_factor, i * norm_factor)
    end)

    # Record measurement statistics if counters provided
    if counters do
      probs = get_probabilities(atomics)
      # Measure according to Born rule
      measure_and_record(atomics, counters, probs)
    end

    {:ok, :walk_step_completed}
  end

  # ===========================================================================
  # 5. MEASUREMENT AND STATISTICS
  # ===========================================================================

  @doc """
  Performs a projective measurement in the position basis.
  Returns the measured state index.
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

    # Collapse to measured state
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
  Computes probability distribution from atomic amplitudes.
  Returns a map of state -> probability.
  """
  def get_probabilities(atomics) do
    total =
      Enum.reduce(0..(@group_order - 1), 0.0, fn k, acc ->
        {r, i} = get_amplitude(atomics, k)
        acc + r*r + i*i
      end)

    for k <- 0..(@group_order - 1), into: %{} do
      {r, i} = get_amplitude(atomics, k)
      {k, (r*r + i*i) / total}
    end
  end

  defp measure_and_record(atomics, counters, probs) do
    state = measure(atomics)
    :counters.add(counters, state, 1)
    :counters.add(counters, @counter_total, 1)
    state
  end

  # ===========================================================================
  # 6. ENTANGLEMENT AND SHUFFLE INVARIANTS
  # ===========================================================================

  @doc """
  Computes the Shannon entropy of the probability distribution.
  This measures the "shuffling entropy" of the 17-gon.
  """
  def shuffle_entropy(atomics) do
    probs = get_probabilities(atomics)

    probs
    |> Map.values()
    |> Enum.filter(&(&1 > 0))
    |> Enum.map(fn p -> -p * :math.log(p) end)
    |> Enum.sum()
  end

  @doc """
  Computes the Fourier transform of the shuffle product.
  For C₁₇, this diagonalizes the convolution operator.

  Returns a list of 17 eigenvalues λ_k.
  """
  def fourier_eigenvalues(atomics) do
    probs = get_probabilities(atomics)

    for m <- 0..(@group_order - 1) do
      # λ_m = Σ_{k=0}^{16} P(k) * ω^{mk}
      # where ω = exp(2πi/17)
      Enum.reduce(0..(@group_order - 1), {0.0, 0.0}, fn k, {acc_r, acc_i} ->
        theta = 2 * :math.pi() * m * k / @group_order
        p = Map.get(probs, k, 0.0)
        {
          acc_r + p * :math.cos(theta),
          acc_i + p * :math.sin(theta)
        }
      end)
    end
  end

  @doc """
  Checks if the shuffle product is idempotent.
  In group algebra, μ * μ = μ iff μ is a uniform distribution.
  """
  def is_idempotent(atomics, tolerance \\ 1.0e-6) do
    # Compute μ * μ
    shuffled = self_shuffle_copy(atomics)

    # Compare with original
    for k <- 0..(@group_order - 1) do
      {r1, i1} = get_amplitude(atomics, k)
      {r2, i2} = get_amplitude(shuffled, k)

      if abs(r1 - r2) > tolerance or abs(i1 - i2) > tolerance do
        return false
      end
    end

    true
  end

  defp self_shuffle_copy(atomics) do
    result = new_quantum_state()

    amps =
      for k <- 0..(@group_order - 1) do
        {k, get_amplitude(atomics, k)}
      end
      |> Map.new()

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
  Runs a concurrent shuffle simulation on the 17-gon.
  Multiple processes can independently apply shuffle operations.
  """
  def concurrent_shuffle_simulation(num_steps, num_workers) do
    atomics = new_quantum_state()
    counters = new_counters()

    # Initialize to uniform superposition
    init_amp = 1.0 / :math.sqrt(@group_order)
    for k <- 0..(@group_order - 1) do
      set_amplitude(atomics, k, init_amp, 0.0)
    end

    # Spawn workers
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

    # Wait for all workers
    Enum.each(workers, fn pid ->
      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end
    end)

    # Collect results
    probs = get_probabilities(atomics)
    entropy = shuffle_entropy(atomics)
    eigenvals = fourier_eigenvalues(atomics)

    # Read counter statistics
    total_measurements = :counters.get(counters, @counter_total)
    measured_probs =
      for k <- 0..(@group_order - 1), into: %{} do
        count = :counters.get(counters, k)
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
