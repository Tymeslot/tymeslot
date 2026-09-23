defmodule Tymeslot.Integrations.HealthCheck.Alerting do
  @moduledoc """
  Aggregate, threshold-based admin alerting on calendar integration health.

  One user's revoked token is a user event: its owner is already emailed to
  reconnect. What the operator needs to hear about is the aggregate, the point
  at which ordinary OAuth churn turns into an incident. So nothing here alerts
  per integration; every alert carries a count, and fires only once that count
  reaches a threshold.

  ## Signals

    * `"availability_refusals"`: organisers whose availability could not be
      computed because a selected calendar could not be read, at least
      `:refusals_per_user` times within the window. Their booking pages offer
      nothing, which is the revenue-affecting symptom. Recorded durably by
      `track_availability/2` from the availability path.
    * `"reauth_flags"`: calendar integrations newly flagged `needs_reauth`
      within the window. A handful a day is churn; a burst in one hour means a
      rotated client secret or a provider outage.
    * `"auto_pause"`: integrations `Tymeslot.Workers.IntegrationAutoPauseWorker`
      gave up on in one run. Reported by that worker via
      `report_auto_pauses/2`, as one alert per run.

  The first two are evaluated hourly by
  `Tymeslot.Workers.IntegrationHealthAlertWorker` over the `:window_hours`
  that ended at the top of the current hour. When a signal that was at or
  above its threshold on the previous hourly evaluation drops back under it,
  `:integration_health_recovery` is raised once.

  ## Configuration

  `config :tymeslot, :integration_health_alerting` (keyword list; every key
  optional, defaults in brackets):

    * `:window_hours` [1]: length of the window each hourly evaluation covers
    * `:refusals_per_user` [5]: refusals within the window before an
      organiser counts as affected, so one visitor retrying through a
      momentary provider blip does not
    * `:affected_users_threshold` [1]: affected organisers before alerting
    * `:reauth_flags_threshold` [10]: new reauth flags within the window
      before alerting
    * `:auto_pause_threshold` [1]: integrations paused in one run before
      alerting

  ## Deduplication

  Admin alert emails are deduplicated for 24 hours per `dedup_key`, and the
  messages here embed live counts, so `AlertTypes.dedup_key/2` keys these
  alerts on the signal and its band instead: `"elevated"` from the threshold,
  `"severe"` from ten times the threshold. A worsening incident therefore
  raises a second alert rather than being swallowed by the first. Auto-pause
  alerts also carry the run's date, because each daily run pauses different
  integrations and the next run falls just inside the 24-hour window.

  Alert metadata carries counts and internal ids only, never user records.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.AvailabilityRefusalQueries

  @unavailable_reasons [:some_calendars_unavailable, :all_calendars_unavailable]

  @defaults [
    window_hours: 1,
    refusals_per_user: 5,
    affected_users_threshold: 1,
    reauth_flags_threshold: 10,
    auto_pause_threshold: 1
  ]

  @severe_multiplier 10

  # Enough ids to start an investigation from, without an unbounded payload
  # when a provider-wide incident affects hundreds.
  @max_listed_ids 20

  @signals [:availability_refusals, :reauth_flags]

  @type signal :: :availability_refusals | :reauth_flags

  @doc "The signals evaluated by `check_signal/2`."
  @spec signals() :: [signal()]
  def signals, do: @signals

  @doc """
  Returns `result` unchanged, first recording a refusal for `user_id` when it
  says the organiser's calendars could not all be read.

  Wraps the availability path's fetch results. Recording never fails the
  caller: a refusal that cannot be written is logged and dropped, because the
  visitor's page matters more than the operator's count.
  """
  @spec track_availability(result, pos_integer() | nil) :: result when result: term()
  def track_availability({:error, reason} = result, user_id)
      when reason in @unavailable_reasons and is_integer(user_id) do
    record_refusal(user_id)
    result
  end

  def track_availability(result, _user_id), do: result

  defp record_refusal(user_id) do
    case AvailabilityRefusalQueries.increment(user_id, hour_start(Clock.utc_now())) do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Could not record availability refusal",
          user_id: user_id,
          errors: inspect(changeset.errors)
        )
    end
  rescue
    exception ->
      Logger.warning("Could not record availability refusal",
        user_id: user_id,
        error: Exception.message(exception)
      )
  end

  @doc """
  Evaluates one signal over the window ending at the top of `now`'s hour,
  raising `:integration_health_failure` at or above its threshold, or
  `:integration_health_recovery` when it has just dropped back under.
  """
  @spec check_signal(signal(), DateTime.t()) :: :alerted | :recovered | :ok
  def check_signal(signal, now \\ Clock.utc_now()) when signal in @signals do
    config = config()
    window_end = hour_start(now)
    threshold = threshold(signal, config)
    current = measure(signal, window_end, config)

    cond do
      current.count >= threshold ->
        report_failure(signal, current, threshold, config)
        :alerted

      measure(signal, DateTime.add(window_end, -1, :hour), config).count >= threshold ->
        report_recovery(signal, current, threshold, config)
        :recovered

      true ->
        :ok
    end
  end

  @doc """
  Raises one `:integration_health_failure` for an auto-pause run, when the
  number of integrations it paused reaches `:auto_pause_threshold`.
  """
  @spec report_auto_pauses(%{calendar: [pos_integer()], video: [pos_integer()]}, DateTime.t()) ::
          :alerted | :ok
  def report_auto_pauses(%{calendar: calendar_ids, video: video_ids}, now \\ Clock.utc_now()) do
    threshold = Keyword.fetch!(config(), :auto_pause_threshold)
    count = length(calendar_ids) + length(video_ids)

    if count >= threshold do
      AdminAlerts.report(:integration_health_failure,
        summary:
          "#{count} integration(s) auto-paused after staying unhealthy " <>
            "(threshold: #{threshold} per run)",
        context: %{
          signal: "auto_pause",
          band: band(count, threshold),
          run_date: now |> DateTime.to_date() |> Date.to_iso8601(),
          count: count,
          threshold: threshold,
          calendar_paused: length(calendar_ids),
          video_paused: length(video_ids),
          calendar_integration_ids: Enum.take(calendar_ids, @max_listed_ids),
          video_integration_ids: Enum.take(video_ids, @max_listed_ids)
        }
      )

      :alerted
    else
      :ok
    end
  end

  defp measure(:availability_refusals, window_end, config) do
    users =
      AvailabilityRefusalQueries.users_refused_at_least(
        window_start(window_end, config),
        window_end,
        Keyword.fetch!(config, :refusals_per_user)
      )

    %{
      count: length(users),
      context: %{
        affected_user_ids: users |> Enum.take(@max_listed_ids) |> Enum.map(&elem(&1, 0)),
        refusals: users |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      }
    }
  end

  defp measure(:reauth_flags, window_end, config) do
    by_provider =
      CalendarIntegrationQueries.count_reauth_flagged_by_provider(
        window_start(window_end, config),
        window_end
      )

    %{count: by_provider |> Map.values() |> Enum.sum(), context: %{by_provider: by_provider}}
  end

  defp report_failure(signal, %{count: count, context: context}, threshold, config) do
    window_hours = Keyword.fetch!(config, :window_hours)

    AdminAlerts.report(:integration_health_failure,
      summary: failure_summary(signal, count, threshold, window_hours, config),
      context:
        Map.merge(context, %{
          signal: Atom.to_string(signal),
          band: band(count, threshold),
          count: count,
          threshold: threshold,
          window_hours: window_hours
        })
    )
  end

  defp report_recovery(signal, %{count: count, context: context}, threshold, config) do
    window_hours = Keyword.fetch!(config, :window_hours)

    AdminAlerts.report(:integration_health_recovery,
      summary:
        "#{signal_label(signal)} back under threshold: #{count} in the last " <>
          "#{window_hours}h (threshold: #{threshold})",
      context:
        Map.merge(context, %{
          signal: Atom.to_string(signal),
          count: count,
          threshold: threshold,
          window_hours: window_hours
        })
    )
  end

  defp failure_summary(:availability_refusals, count, threshold, window_hours, config) do
    "#{count} organiser(s) served no availability because a selected calendar " <>
      "could not be read (#{Keyword.fetch!(config, :refusals_per_user)}+ refusals each " <>
      "in the last #{window_hours}h, threshold: #{threshold})"
  end

  defp failure_summary(:reauth_flags, count, threshold, window_hours, _config) do
    "#{count} calendar integration(s) newly flagged for reconnection in the last " <>
      "#{window_hours}h (threshold: #{threshold})"
  end

  defp signal_label(:availability_refusals), do: "Calendar availability refusals"
  defp signal_label(:reauth_flags), do: "Calendar reconnection flags"

  defp threshold(:availability_refusals, config),
    do: Keyword.fetch!(config, :affected_users_threshold)

  defp threshold(:reauth_flags, config), do: Keyword.fetch!(config, :reauth_flags_threshold)

  defp band(count, threshold) when count >= threshold * @severe_multiplier, do: "severe"
  defp band(_count, _threshold), do: "elevated"

  defp window_start(window_end, config),
    do: DateTime.add(window_end, -Keyword.fetch!(config, :window_hours), :hour)

  defp hour_start(%DateTime{} = datetime),
    do: %{DateTime.truncate(datetime, :second) | minute: 0, second: 0}

  defp config do
    Keyword.merge(@defaults, Application.get_env(:tymeslot, :integration_health_alerting, []))
  end
end
