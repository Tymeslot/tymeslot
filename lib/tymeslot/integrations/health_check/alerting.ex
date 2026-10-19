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
  that ended at the top of the current hour. A signal is back to normal only
  once it has stayed under its threshold for `:recover_after` consecutive
  windows, and `:integration_health_recovery` is raised once, then. A dip
  shorter than that is part of the same incident: one organiser's dead
  calendar, whose page is visited more than the threshold in some hours and
  less in others, is one incident with one alert, not an alert and a
  recovery every other hour.

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
    * `:recover_after` [2]: consecutive windows under the threshold before a
      signal counts as recovered; a shorter dip belongs to the incident. At
      least 1: anything else raises `ArgumentError`

  ## Deduplication

  Admin alert emails are deduplicated for 24 hours per `dedup_key`, and the
  messages here embed live counts, so `AlertTypes.dedup_key/2` keys these
  alerts on the signal and its band instead: `"elevated"` from the threshold,
  `"severe"` from ten times the threshold. A worsening incident therefore
  raises a second alert rather than being swallowed by the first. Auto-pause
  alerts also carry the run's date, because each daily run pauses different
  integrations and the next run falls just inside the 24-hour window.

  The two hourly signals also carry the hour their incident began, and their
  recovery carries the same hour. Without it a second incident on the day of
  a first one (alert, recovery, then trouble again) would share the first
  one's keys and be swallowed whole, leaving the recovery as the last word
  the operator heard. An incident older than the dedup window reports no
  start, so a long one is reminded of once a day.

  ## State

  Each hourly signal's state (quiet or in an incident, the incident's start,
  the last window at or above the threshold, the last window evaluated) is
  persisted in `integration_health_alert_states`, so each run measures one
  window instead of walking back over up to a day of them. A signal with no
  state yet, as on the first run after upgrading, has it rebuilt once from
  the windows behind it.

  Alert metadata carries counts and internal ids only, never user records.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.{AlertStateQueries, AlertStateSchema}
  alias Tymeslot.Integrations.HealthCheck.AvailabilityRefusalQueries
  alias Tymeslot.Repo

  @unavailable_reasons [:some_calendars_unavailable, :all_calendars_unavailable]

  @defaults [
    window_hours: 1,
    refusals_per_user: 5,
    affected_users_threshold: 1,
    reauth_flags_threshold: 10,
    auto_pause_threshold: 1,
    recover_after: 2
  ]

  @severe_multiplier 10

  # Enough ids to start an investigation from, without an unbounded payload
  # when a provider-wide incident affects hundreds.
  @max_listed_ids 20

  @signals [:availability_refusals, :reauth_flags]

  # How far back an incident's start is looked for: the admin alert dedup
  # window, beyond which a start no longer changes which alerts collapse.
  @max_incident_lookback_hours 24

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
          errors: LogFormat.reason(changeset.errors)
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
  `:integration_health_recovery` once it has stayed under it for
  `:recover_after` windows in a row.

  The signal's state (quiet or in an incident, since when, last window at or
  above the threshold) is read and written under a row lock, so a window
  already evaluated is not evaluated again.
  """
  @spec check_signal(signal(), DateTime.t()) :: :alerted | :recovered | :ok
  def check_signal(signal, now \\ Clock.utc_now()) when signal in @signals do
    config = config()
    window_end = hour_start(now)
    threshold = threshold(signal, config)

    {:ok, outcome} =
      Repo.transaction(fn ->
        state =
          AlertStateQueries.get_for_update(Atom.to_string(signal)) ||
            reconstruct_state(signal, window_end, threshold, config)

        if state.last_window_end && DateTime.compare(state.last_window_end, window_end) != :lt do
          :already_evaluated
        else
          current = measure(signal, window_end, config)
          {outcome, state} = step(state, current.count >= threshold, window_end, config)
          AlertStateQueries.put(%{state | last_window_end: window_end})
          {outcome, current, state}
        end
      end)

    report(signal, outcome, threshold, window_end, config)
  end

  # Within an incident each window at or above the threshold re-reports it
  # (collapsed by the dedup key), and the incident ends once the signal has
  # been under the threshold for `:recover_after` windows since it was last at
  # or above it. A shorter dip is part of the same incident.
  defp step(%{status: :raised} = state, true = _above?, window_end, _config),
    do: {:alerted, %{state | last_above_at: window_end}}

  defp step(state, true = _above?, window_end, _config),
    do:
      {:alerted,
       %{state | status: :raised, incident_started_at: window_end, last_above_at: window_end}}

  defp step(%{status: :raised} = state, false = _above?, window_end, config) do
    if DateTime.diff(window_end, state.last_above_at, :hour) >=
         Keyword.fetch!(config, :recover_after),
       do: {:recovered, %{state | status: :quiet}},
       else: {:ok, state}
  end

  defp step(state, false = _above?, _window_end, _config), do: {:ok, state}

  defp report(_signal, :already_evaluated, _threshold, _window_end, _config), do: :ok
  defp report(_signal, {:ok, _current, _state}, _threshold, _window_end, _config), do: :ok

  defp report(signal, {:alerted, current, state}, threshold, window_end, config) do
    report_failure(signal, current, threshold, reported_start(state, window_end), config)
    :alerted
  end

  defp report(signal, {:recovered, current, state}, threshold, _window_end, config) do
    report_recovery(
      signal,
      current,
      threshold,
      reported_start(state, state.last_above_at),
      config
    )

    :recovered
  end

  # The incident's start goes into the dedup key, so a second incident on the
  # day of a first is not swallowed by the first one's keys. Once the
  # incident is older than the dedup window its start is left out, so a long
  # incident is reminded of once a day rather than never.
  defp reported_start(%{incident_started_at: nil}, _at), do: nil

  defp reported_start(%{incident_started_at: started_at}, at) do
    if DateTime.diff(at, started_at, :hour) < @max_incident_lookback_hours,
      do: DateTime.to_iso8601(started_at)
  end

  # A signal with no persisted state yet, as on the first run after upgrading
  # to persisted state, has its state as of the previous window rebuilt from
  # the windows behind it: in an incident if any of the last `:recover_after`
  # windows was at or above the threshold, with the incident's start found by
  # walking back. So the first run neither raises a fresh alert for an
  # incident already reported nor drops the recovery of one.
  defp reconstruct_state(signal, window_end, threshold, config) do
    recover_after = Keyword.fetch!(config, :recover_after)

    last_above =
      Enum.find_value(1..recover_after//1, fn back ->
        earlier = DateTime.add(window_end, -back, :hour)
        if measure(signal, earlier, config).count >= threshold, do: earlier
      end)

    state = %AlertStateSchema{signal: Atom.to_string(signal), status: :quiet}

    if last_above,
      do: %{
        state
        | status: :raised,
          last_above_at: last_above,
          incident_started_at: incident_started_at(signal, last_above, threshold, config)
      },
      else: state
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

  # The end of the earliest window at or above the threshold in the run that
  # ends with the one ending at `window_end`, where a dip of fewer than
  # `:recover_after` windows does not break the run, or nil when the run
  # reaches further back than the lookback.
  defp incident_started_at(signal, window_end, threshold, config) do
    walk_back(
      signal,
      window_end,
      threshold,
      config,
      @max_incident_lookback_hours,
      Keyword.fetch!(config, :recover_after)
    )
  end

  defp walk_back(_signal, _start, _threshold, _config, 0, _recover_after), do: nil

  defp walk_back(signal, start, threshold, config, hours_left, recover_after) do
    reach = min(recover_after, hours_left)

    case earlier_window_above(signal, start, threshold, config, reach) do
      {earlier, back} ->
        walk_back(signal, earlier, threshold, config, hours_left - back, recover_after)

      nil when reach == recover_after ->
        start

      nil ->
        nil
    end
  end

  # The nearest window at or above the threshold within `reach` windows
  # before `start`, with how many windows back it lies.
  defp earlier_window_above(signal, start, threshold, config, reach) do
    Enum.find_value(1..reach//1, fn back ->
      earlier = DateTime.add(start, -back, :hour)
      if measure(signal, earlier, config).count >= threshold, do: {earlier, back}
    end)
  end

  defp report_failure(signal, %{count: count, context: context}, threshold, started_at, config) do
    window_hours = Keyword.fetch!(config, :window_hours)

    AdminAlerts.report(:integration_health_failure,
      summary: failure_summary(signal, count, threshold, window_hours, config),
      context:
        Map.merge(context, %{
          signal: Atom.to_string(signal),
          band: band(count, threshold),
          incident_started_at: started_at,
          count: count,
          threshold: threshold,
          window_hours: window_hours
        })
    )
  end

  defp report_recovery(signal, %{count: count, context: context}, threshold, started_at, config) do
    window_hours = Keyword.fetch!(config, :window_hours)

    AdminAlerts.report(:integration_health_recovery,
      summary:
        "#{signal_label(signal)} back under threshold: #{count} in the last " <>
          "#{window_hours}h (threshold: #{threshold})",
      context:
        Map.merge(context, %{
          signal: Atom.to_string(signal),
          incident_started_at: started_at,
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

  @doc """
  Refuses a configuration the hourly check could not run on: a signal can
  only recover after at least one quiet window, and with fewer the look back
  over the quiet windows covers nothing, so every window under the threshold
  would read as a fresh recovery. Called at boot, so a bad value stops the
  application starting instead of raising in every hourly alert run.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    case Keyword.fetch!(config(), :recover_after) do
      windows when is_integer(windows) and windows >= 1 ->
        :ok

      other ->
        raise ArgumentError,
              "config :tymeslot, :integration_health_alerting, recover_after: must be a " <>
                "positive integer, got: #{inspect(other)}"
    end
  end

  defp config do
    Keyword.merge(@defaults, Application.get_env(:tymeslot, :integration_health_alerting, []))
  end
end
