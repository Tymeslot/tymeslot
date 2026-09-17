defmodule Tymeslot.Precommit.CpuBudget do
  @moduledoc """
  Sizes the partitioned test suite in `mix precommit` to the CPU that is free
  when the suite starts, rather than to the machine.

  ## Why measure instead of assuming the machine is idle

  The gate is often run while something else is busy: another worktree's suite,
  a dev server, a build. A partition count fixed for an idle 16-core host then
  oversubscribes the machine, which makes the run slower rather than faster
  (schedulers thrash, sandbox checkouts queue) and makes timing-sensitive tests
  flaky. So the budget is taken from what is actually idle at the moment the
  suite starts, and each partition is capped to its share of it.

  Two limits apply, and the smaller wins:

    * **The CPU the BEAM may use.** `System.schedulers_online/0` already honours
      a cgroup CPU quota (such as the systemd scope the workspace `mix.sh`
      runs under), so it is the ceiling.
    * **The CPU that is idle.** Sampled from `/proc/stat` over a short window.
      Where that file does not exist (macOS, BSD), the sample is skipped and
      the ceiling alone applies.

  The sample is a snapshot: load that arrives after the suite has started is
  not seen. That is acceptable because the caps below keep the suite to a known
  footprint, so late arrivals share the machine with a bounded run instead of
  an unbounded one.

  ## The numbers

  Measured on a 16-core host, whole Core suite, all partitions in parallel:
  126s unpartitioned, 73s at 4 partitions, about 60s at 6 and 60s at 8, so the
  gain flattens past 6. Capping each of 6 partitions to 3 schedulers cost 9%
  against uncapped (60.7s against 55.8s) while using half the CPU. Hence one
  partition per three free cores, at most six, each capped to its share.

  `PRECOMMIT_TEST_PARTITIONS` overrides the partition count (`1` runs the suite
  as a single partition); the scheduler cap still follows the budget. A run
  whose `MIX_TEST_PARTITION` is already a number is someone partitioning by
  hand, and gets no plan, so the suite runs whole as they set it up.
  """

  @cores_per_partition 3
  @max_partitions 6
  @min_schedulers 2
  @sample_ms 500

  @type plan :: %{partitions: pos_integer(), schedulers: pos_integer()}

  @doc "Plans the suite against the CPU that is free right now."
  @spec suite_plan() :: plan() | nil
  def suite_plan do
    if parse_positive(System.get_env("MIX_TEST_PARTITION", "")) do
      nil
    else
      plan(available_cores(), parse_positive(System.get_env("PRECOMMIT_TEST_PARTITIONS", "")))
    end
  end

  @doc """
  Plans the suite for a given number of free cores, optionally forcing the
  partition count.
  """
  @spec plan(pos_integer(), pos_integer() | nil) :: plan()
  def plan(cores, partitions \\ nil) do
    partitions = partitions || partitions_for(cores)
    %{partitions: partitions, schedulers: max(div(cores, partitions), @min_schedulers)}
  end

  @doc "Cores free for the suite: idle CPU, capped at what the BEAM may schedule."
  @spec available_cores() :: pos_integer()
  def available_cores do
    ceiling = System.schedulers_online()

    case idle_cores() do
      {:ok, idle} -> idle |> min(ceiling) |> max(1)
      :error -> ceiling
    end
  end

  @doc """
  Idle cores over the sample window, computed from two `/proc/stat` readings.
  """
  @spec idle_cores(non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def idle_cores(sample_ms \\ @sample_ms) do
    with {:ok, before} <- read_stat(),
         :ok <- Process.sleep(sample_ms),
         {:ok, later} <- read_stat() do
      {:ok, idle_between(before, later)}
    end
  end

  @doc false
  @spec idle_between(map(), map()) :: non_neg_integer()
  def idle_between(%{idle: idle0, total: total0, cpus: cpus}, %{idle: idle1, total: total1}) do
    case total1 - total0 do
      elapsed when elapsed > 0 -> round(cpus * (idle1 - idle0) / elapsed)
      _no_time_passed -> cpus
    end
  end

  @doc false
  @spec parse_stat(String.t()) :: {:ok, map()} | :error
  def parse_stat(contents) do
    lines = String.split(contents, "\n")
    cpus = Enum.count(lines, &Regex.match?(~r/^cpu\d+ /, &1))

    with ["cpu " <> totals | _rest] <- lines,
         [user, nice, system, idle, iowait, irq, softirq, steal | _guest] <-
           totals |> String.split() |> Enum.map(&String.to_integer/1),
         true <- cpus > 0 do
      {:ok,
       %{
         idle: idle + iowait,
         total: user + nice + system + idle + iowait + irq + softirq + steal,
         cpus: cpus
       }}
    else
      _unreadable -> :error
    end
  end

  defp read_stat do
    case File.read("/proc/stat") do
      {:ok, contents} -> parse_stat(contents)
      {:error, _reason} -> :error
    end
  end

  defp partitions_for(cores) do
    cores |> div(@cores_per_partition) |> max(1) |> min(@max_partitions)
  end

  defp parse_positive(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _invalid -> nil
    end
  end
end
