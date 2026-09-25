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

  Measured on a 16-core host, whole Core suite, all partitions in parallel:
  126s unpartitioned, 73s at 4 partitions, about 60s at 6 and 60s at 8, so the
  gain flattens past 6. Capping each of 6 partitions to 3 schedulers cost 9%
  against uncapped (60.7s against 55.8s) while using half the CPU. Hence one
  partition per three allowed cores, at most six, each capped to its share.

  `PRECOMMIT_TEST_PARTITIONS` overrides the partition count (`1` runs the suite
  as a single partition); the scheduler cap still follows the allowance. A run
  whose `MIX_TEST_PARTITION` is already a number is someone partitioning by
  hand, and gets no plan, so the suite runs whole as they set it up.
  """

  @cores_per_partition 3
  @max_partitions 6
  @min_schedulers 2

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
  Plans the suite for a given number of cores, optionally forcing the partition
  count.
  """
  @spec plan(pos_integer(), pos_integer() | nil) :: plan()
  def plan(cores, partitions \\ nil) do
    partitions = partitions || partitions_for(cores)
    %{partitions: partitions, schedulers: max(div(cores, partitions), @min_schedulers)}
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
