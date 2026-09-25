defmodule Tymeslot.Infrastructure.ObanRescue do
  @moduledoc """
  Checks that the Oban configuration can recover a job whose node died mid-run.

  `shutdown_grace_period` only waits for in-flight jobs: whatever is still
  running when it expires is killed with its row left `executing`, and
  open-source Oban never reschedules that row on its own. A deploy landing
  while a booking's video room job is mid-request therefore strands the job,
  and with it the confirmation the job was holding back.

  Two mechanisms clear an abandoned row, and the order between them is the
  whole point:

  1. `Oban.Lifeline` returns the job to `available` once it has been
     `executing` for `rescue_after`, so it runs again on a live node. This is
     the one that recovers the work, and Oban only starts it when the
     `:lifeline` key is present in the configuration.
  2. `Tymeslot.Workers.ObanMaintenanceWorker` discards whatever is still
     `executing` after `discard_after_hours/0`. A discarded job never runs
     again, so that sweep is the backstop for an installation whose lifeline
     is missing or whose leader is unreachable, and it has to sit well behind
     the rescue rather than in front of it.

  Rescuing goes purely on elapsed time, with no idea whether the node running
  the job is still alive, so a window shorter than the longest legitimate run
  re-runs jobs that are still working and duplicates their side effects. No
  worker sets an Oban `timeout/1`, so nothing caps a run from above; the
  longest bounded one is an Exchange calendar sync draining up to 500 pages at
  30 seconds each, a little over four hours, which is what
  `@longest_job_hours` records.

  The check reads the raw application environment rather than Oban's own
  normalised state, so it has to know the shapes a service key accepts: a
  keyword list of options, a `{module, options}` tuple, a bare module, or
  `false` to switch the service off.
  """

  require Logger

  alias Oban.Period

  # The longest a job may legitimately hold a queue's worker. See the moduledoc
  # for where the figure comes from; it is rounded up from the Exchange sync's
  # 500 pages at 30 seconds each.
  @longest_job_hours 5
  @longest_job_ms :timer.hours(@longest_job_hours)

  # How long an `executing` row survives before the maintenance sweep discards
  # it. Comfortably behind the rescue window, so the backstop cannot pre-empt
  # the recovery it exists to back up.
  @discard_after_hours 12
  @discard_after_ms :timer.hours(@discard_after_hours)

  # Oban's own default when `:lifeline` is configured without a `rescue_after`.
  @oban_default_rescue_after_ms :timer.hours(1)

  @type problem ::
          :missing
          | {:rescues_too_soon, pos_integer()}
          | {:rescues_after_discard, pos_integer()}

  @doc """
  How long a job may sit `executing` before the maintenance sweep discards it.

  `Tymeslot.Workers.ObanMaintenanceWorker` reads its threshold from here so
  that the two ends of the ladder cannot drift apart.
  """
  @spec discard_after_hours() :: pos_integer()
  def discard_after_hours, do: @discard_after_hours

  @doc """
  Whether `oban_config` can recover a job abandoned by a stopped node.

  Returns `:ok`, or the single thing wrong with the `:lifeline` service:

  * `:missing` when the service is absent or disabled, which costs recovery
    altogether.
  * `{:rescues_too_soon, ms}` when the window is short enough to re-run jobs
    that are still working.
  * `{:rescues_after_discard, ms}` when the maintenance sweep discards a row
    before the rescue is due, which leaves the rescue unreachable.
  """
  @spec check(keyword()) :: :ok | problem()
  def check(oban_config) do
    oban_config
    |> Keyword.get(:lifeline)
    |> rescue_after_ms()
    |> classify()
  end

  @doc """
  Logs a warning when `oban_config` cannot recover an abandoned job.
  """
  @spec warn_on_unsafe_lifeline(keyword()) :: :ok
  def warn_on_unsafe_lifeline(oban_config) do
    oban_config
    |> check()
    |> warn()
  end

  defp classify(:none), do: :missing
  defp classify(ms) when ms < @longest_job_ms, do: {:rescues_too_soon, ms}
  defp classify(ms) when ms >= @discard_after_ms, do: {:rescues_after_discard, ms}
  defp classify(_ms), do: :ok

  defp rescue_after_ms(disabled) when disabled in [nil, false], do: :none
  defp rescue_after_ms({_module, opts}) when is_list(opts), do: from_options(opts)
  defp rescue_after_ms(opts) when is_list(opts), do: from_options(opts)

  # Named as a bare module, so the plugin runs on its own defaults.
  defp rescue_after_ms(module) when is_atom(module), do: @oban_default_rescue_after_ms

  defp from_options(opts) do
    opts
    |> Keyword.get(:rescue_after, @oban_default_rescue_after_ms)
    |> Period.to_milliseconds()
  end

  defp warn(:ok), do: :ok

  defp warn(:missing) do
    Logger.warning(
      """
      OBAN LIFELINE NOT CONFIGURED:
      Oban's `lifeline:` service is missing or disabled, so a job whose node
      stopped mid-run stays `executing` for good. Every job a deploy interrupts
      is lost along with the emails and calendar events it owed, and the
      maintenance sweep only discards the rows afterwards. Add
      `lifeline: [rescue_after: {N, :hours}]` to the Oban config.
      """,
      discard_after_hours: @discard_after_hours
    )
  end

  defp warn({:rescues_too_soon, rescue_after_ms}) do
    Logger.warning(
      "Oban lifeline rescues a job after #{in_hours(rescue_after_ms)} hours, ahead of the " <>
        "#{@longest_job_hours} hours the longest job may legitimately take. Rescuing goes on " <>
        "elapsed time alone, so jobs that are still running will be started a second time and " <>
        "their side effects duplicated."
    )
  end

  defp warn({:rescues_after_discard, rescue_after_ms}) do
    Logger.warning(
      "Oban lifeline rescues a job after #{in_hours(rescue_after_ms)} hours, behind the " <>
        "#{@discard_after_hours} hours after which the maintenance sweep discards it. A job " <>
        "abandoned by a stopped node is discarded rather than rescued, and a discarded job " <>
        "never runs again."
    )
  end

  defp in_hours(milliseconds), do: Float.round(milliseconds / :timer.hours(1), 1)
end
