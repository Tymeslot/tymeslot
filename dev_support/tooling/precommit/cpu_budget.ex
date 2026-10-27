defmodule Tymeslot.Precommit.CpuBudget do
  @moduledoc """
  Sizes the partitioned test suite in `mix precommit` so that, together, its
  partitions use about as many schedulers as the run is allowed cores, and no
  more.

  ## Why the footprint follows the CPU allowance, not the idle CPU

  Partitions multiply schedulers: six `mix test` processes on a 16-core host
  would each start 16 by default, and the run would oversubscribe the machine
  on its own, which slows it down (schedulers thrash, sandbox checkouts queue)
  and stretches the latency of every test past the margins timing-sensitive
  tests allow. So each partition is capped to its share of the allowance.

  The allowance is `System.schedulers_online/0`, which already honours a cgroup
  CPU quota: a run under a hard cap (such as `MIX_CPU_QUOTA` in the workspace
  `mix.sh`) gets proportionally fewer and smaller partitions.

  What the allowance deliberately ignores is how busy the machine is. Sizing to
  a sample of idle CPU was tried, and a sample is a guess about the next minute
  made from the last half second: taken while the other repository's gate was
  compiling alongside it, it planned a single partition of three schedulers and
  the suite took 497s instead of about 60s. CPU that other work wants is
  arbitrated continuously by the kernel instead: the workspace `mix.sh` runs mix
  under a reduced systemd `CPUWeight`, so the suite takes every core nothing
  else wants and yields a proportional share to whatever does, however that
  changes during the run.

  ## The numbers

  The suite's wall clock is its synchronous modules, which are bound by
  latency (database round trips, timeouts, process hand-offs) rather than CPU,
  so what shortens it is how many partitions run them side by side, not how
  many schedulers each one has. Measured on a container host with a 9-CPU
  quota, whole Core suite, partitions alone: 496s as 1 partition of 4
  schedulers, 394s as 2 of 2, 262s as 3 of 2, and 234s as 4 of 2 and as 4 of
  1 alike. Four
  partitions of one scheduler run the suite in under half the time of one
  partition of four, on the same allowance. Given all 9 CPUs, 6 of 1 took
  187s against 223s for 3 of 3.

  On a 16-core host the gain flattened past 6 partitions (126s whole, 73s at
  4, about 60s at 6 and at 8), and capping each of 6 partitions to 3
  schedulers cost 9% against uncapped while using half the CPU. Hence one
  partition per allowed core, at most six, each capped to its share. This
  matters most on a small allowance, such as the share the workspace `mix.sh`
  gives each of two gates run side by side: at three cores per partition, a
  4-core share planned a single partition and the suite ran serially for ten
  minutes.

  `PRECOMMIT_TEST_PARTITIONS` overrides the partition count (`1` runs the suite
  as a single partition); the scheduler cap still follows the allowance. A run
  whose `MIX_TEST_PARTITION` is already a number is someone partitioning by
  hand, and gets no plan, so the suite runs whole as they set it up.
  """

  @max_partitions 6
  @min_schedulers 1

  @type plan :: %{partitions: pos_integer(), schedulers: pos_integer()}

  @doc "Plans the suite for the cores this run may use."
  @spec suite_plan() :: plan() | nil
  def suite_plan do
    if parse_positive(System.get_env("MIX_TEST_PARTITION", "")) do
      nil
    else
      plan(
        System.schedulers_online(),
        parse_positive(System.get_env("PRECOMMIT_TEST_PARTITIONS", ""))
      )
    end
  end

  @doc """
  The `:suite_plan` for `Tymeslot.Precommit.Runner`, given the suite the run
  takes: `Tymeslot.Precommit.Affected`'s narrowed suite, or `nil` for the whole
  one.

  A selection is partitioned like the full suite, since it can still be
  thousands of tests, but never into more partitions than it has files: `mix
  test --partitions` deals files out one per partition in turn, and a
  partition dealt none exits 1.
  """
  @spec planner(map() | :upstream | nil) :: (-> plan() | nil)
  def planner(%{scope: :selection, files: files}) do
    fn ->
      case suite_plan() do
        %{partitions: count} = plan -> %{plan | partitions: min(count, length(files))}
        nil -> nil
      end
    end
  end

  def planner(_suite), do: &suite_plan/0

  @doc """
  Plans the suite for a given number of cores, optionally forcing the partition
  count.
  """
  @spec plan(pos_integer(), pos_integer() | nil) :: plan()
  def plan(cores, partitions \\ nil) do
    partitions = partitions || partitions_for(cores)
    %{partitions: partitions, schedulers: max(div(cores, partitions), @min_schedulers)}
  end

  defp partitions_for(cores) do
    min(cores, @max_partitions)
  end

  defp parse_positive(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _invalid -> nil
    end
  end
end
