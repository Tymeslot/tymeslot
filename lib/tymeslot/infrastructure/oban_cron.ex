defmodule Tymeslot.Infrastructure.ObanCron do
  @moduledoc """
  Checks the `:cron` section of the Oban configuration for the maintenance
  workers the system depends on.

  `Tymeslot.Workers.ObanMaintenanceWorker`,
  `Tymeslot.Workers.ObanQueueMonitorWorker`,
  `Tymeslot.Workers.ErrorTrackerMaintenanceWorker` and
  `Tymeslot.Workers.AdminAlertDigestWorker` run from the crontab and nowhere
  else. Without them jobs accumulate, queue problems go unreported, stored
  errors are never resolved or pruned, and info alerts never reach the
  operator. Nothing else notices they are gone, so startup says so loudly
  rather than degrading in silence.

  The check reads the raw application environment rather than Oban's own
  normalised state, so it has to know the shapes `:cron` accepts: a keyword
  list, a `{module, opts}` tuple, a bare module, or `false` to disable the
  service outright. Only the first two can carry a crontab of ours.

  It also builds the crontab: the environment's Oban configuration only
  switches the cron service on, and `extend/1` fills in Core's own entries
  (`:oban_crontab`, one definition shared by dev and production) followed by
  the `:oban_additional_crontab` entries a wrapper application schedules.
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @critical_workers [
    Tymeslot.Workers.ObanMaintenanceWorker,
    Tymeslot.Workers.ObanQueueMonitorWorker,
    Tymeslot.Workers.ErrorTrackerMaintenanceWorker,
    Tymeslot.Workers.AdminAlertDigestWorker
  ]

  @doc """
  Returns `oban_config` with Core's crontab (`base_crontab/0`) and then the
  `:oban_additional_crontab` entries appended to its crontab: the latter is
  the extension point through which a wrapper application schedules its own
  periodic workers, mirroring `:oban_additional_queues`.

  Scheduling them here rather than from each worker re-inserting its own next
  run means a run that crashes cannot end the schedule, and runs stay on the
  clock instead of drifting a little later every day.

  With the `:cron` service absent or disabled (the test environment, for one)
  there is no crontab to extend and the configuration is returned unchanged.
  Raises `ArgumentError` when the additional crontab is not a list.
  """
  @spec extend(keyword()) :: keyword()
  def extend(oban_config) do
    additional = Application.get_env(:tymeslot, :oban_additional_crontab, [])

    extend(
      oban_config,
      if(is_list(additional), do: base_crontab() ++ additional, else: additional)
    )
  end

  @doc """
  Core's own crontab, the `:oban_crontab` entries in `config/config.exs`.
  """
  @spec base_crontab() :: list()
  def base_crontab, do: Application.get_env(:tymeslot, :oban_crontab, [])

  @doc false
  @spec extend(keyword(), term()) :: keyword()
  def extend(oban_config, []), do: oban_config

  def extend(oban_config, additional) when is_list(additional) do
    case Keyword.get(oban_config, :cron) do
      {module, opts} when is_list(opts) ->
        Keyword.put(oban_config, :cron, {module, append_crontab(opts, additional)})

      opts when is_list(opts) ->
        Keyword.put(oban_config, :cron, append_crontab(opts, additional))

      _absent_or_disabled ->
        oban_config
    end
  end

  def extend(_oban_config, additional) do
    raise ArgumentError,
          ":oban_additional_crontab must be a list of crontab entries, got: " <>
            inspect(additional)
  end

  defp append_crontab(opts, additional),
    do: Keyword.update(opts, :crontab, additional, &(&1 ++ additional))

  @doc """
  The critical workers `oban_config` fails to schedule.

  `:no_crontab` means the `:cron` service itself is absent or disabled, which
  costs every critical worker at once and is worth reporting as its own thing.
  """
  @spec missing_workers(keyword()) :: [module()] | :no_crontab
  def missing_workers(oban_config) do
    case crontab(Keyword.get(oban_config, :cron)) do
      nil -> :no_crontab
      crontab -> Enum.reject(@critical_workers, &scheduled?(crontab, &1))
    end
  end

  @doc """
  Logs a warning for each critical worker `oban_config` does not schedule.
  """
  @spec warn_on_missing_workers(keyword()) :: :ok
  def warn_on_missing_workers(oban_config) do
    oban_config
    |> missing_workers()
    |> warn()
  end

  defp warn(:no_crontab) do
    Logger.warning(
      """
      OBAN CRON SERVICE NOT CONFIGURED:
      Oban's `cron:` service is missing or disabled, so it carries no crontab.
      The critical maintenance workers will not run, which leads to job
      accumulation and queue problems going unreported. Add
      `cron: [crontab: [...]]` to the Oban config with the required jobs.
      """,
      critical_workers: LogFormat.reason(@critical_workers)
    )
  end

  defp warn(missing_workers) do
    Enum.each(missing_workers, fn worker ->
      Logger.warning(
        "Critical Oban worker not scheduled in the cron service: #{inspect(worker)}. " <>
          "This worker should run periodically for system health."
      )
    end)
  end

  defp crontab({_module, opts}) when is_list(opts), do: Keyword.get(opts, :crontab)
  defp crontab(opts) when is_list(opts), do: Keyword.get(opts, :crontab)

  # Absent, `false`, or an alternative implementation named as a bare module:
  # no crontab of ours to read.
  defp crontab(_other), do: nil

  defp scheduled?(crontab, worker) do
    Enum.any?(crontab, fn
      {_schedule, ^worker} -> true
      {_schedule, ^worker, _opts} -> true
      _other -> false
    end)
  end
end
