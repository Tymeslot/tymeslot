defmodule Tymeslot.Availability.Audit do
  @moduledoc """
  On-demand diagnostic that compares the calendar-grid boolean
  (`Calculate.range_availability/6`) against the per-day time-picker
  enumeration (`Calculate.available_slots/6`) for a profile, reporting any
  divergence between what users see in the calendar grid and what the time
  picker would actually offer.

  The two paths must agree by construction (both enumerate the same
  discrete slot grid), so a non-empty `:disagreements` list indicates a
  regression or a data-state edge case worth investigating.

  Intended for manual investigation in `bin/tymeslot remote` when a user
  reports unexpected availability:

      iex> Tymeslot.Availability.Audit.run("alice")

  Returns `{:ok, result}` with the full audit data; prints a human-readable
  report to stdout by default. Pass `print: false` to suppress.
  """

  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.WeeklyAvailabilityQueries
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Profiles.ProfileQueries

  @default_duration_minutes 30
  @default_horizon_days 30

  @type disagreement :: %{
          required(:date) => Date.t(),
          required(:day_of_week) => 1..7,
          required(:month_view_says_bookable) => boolean(),
          required(:per_day_has_slots) => boolean(),
          required(:per_day_slot_count) => non_neg_integer(),
          required(:per_day_event_count) => non_neg_integer()
        }

  @type result :: %{
          required(:profile_id) => pos_integer(),
          required(:username) => String.t() | nil,
          required(:horizon) => {Date.t(), Date.t()},
          required(:duration_minutes) => pos_integer(),
          required(:checked_days) => pos_integer(),
          required(:disagreements) => [disagreement()]
        }

  @doc """
  Audits a profile by username. Returns `{:ok, result}` on success or
  `{:error, :not_found}` if no profile exists for that username.

  Prints a human-readable summary to stdout unless `print: false`.

  ## Options

    * `:duration_minutes` — meeting duration in minutes (default `30`)
    * `:horizon_days` — how far ahead to check from `:start_date` (default `30`)
    * `:start_date` — first date to audit (default today UTC)
    * `:print` — set to `false` to suppress IO (default `true`)
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, :not_found}
  def run(username, opts \\ []) do
    case ProfileQueries.get_by_username_with_user(username) do
      {:ok, profile} ->
        result = audit(profile, opts)
        if Keyword.get(opts, :print, true), do: print_report(result)
        {:ok, result}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  @doc """
  Same as `run/2` but takes an already-loaded profile schema. Always
  returns the result map; never prints.
  """
  @spec audit(map(), keyword()) :: result()
  def audit(profile, opts \\ []) do
    duration_minutes = Keyword.get(opts, :duration_minutes, @default_duration_minutes)
    horizon_days = Keyword.get(opts, :horizon_days, @default_horizon_days)
    start_date = Keyword.get(opts, :start_date, Date.utc_today())
    end_date = Date.add(start_date, horizon_days)
    timezone = profile.timezone

    integration_ids =
      profile.user_id
      |> CalendarIntegrationQueries.list_active_for_user()
      |> Enum.map(& &1.id)

    weekly_schedule = WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(profile.id)

    overrides =
      AvailabilityOverrideQueries.get_overrides_by_profile_and_date_range(
        profile.id,
        start_date,
        end_date
      )

    config = %{
      profile_id: profile.id,
      duration_minutes: duration_minutes,
      buffer_minutes: profile.buffer_minutes,
      max_advance_booking_days: profile.advance_booking_days,
      min_advance_hours: profile.min_advance_hours,
      owner_timezone: timezone,
      weekly_schedule: weekly_schedule,
      overrides: overrides
    }

    range_events = CalendarEventQueries.in_range(integration_ids, {start_date, end_date})

    {:ok, month_view} =
      Calculate.range_availability(start_date, end_date, timezone, timezone, range_events, config)

    disagreements =
      start_date
      |> Date.range(end_date)
      |> Enum.flat_map(&compare_one_date(&1, month_view, integration_ids, config, timezone))

    %{
      profile_id: profile.id,
      username: profile.username,
      horizon: {start_date, end_date},
      duration_minutes: duration_minutes,
      checked_days: Date.diff(end_date, start_date) + 1,
      disagreements: disagreements
    }
  end

  defp compare_one_date(date, month_view, integration_ids, config, timezone) do
    month_says = Map.get(month_view, Date.to_iso8601(date), false)

    day_events = CalendarEventQueries.in_range(integration_ids, {date, date})

    {:ok, slots} =
      Calculate.available_slots(
        date,
        config.duration_minutes,
        timezone,
        timezone,
        day_events,
        config
      )

    per_day_says = slots != []

    if month_says == per_day_says do
      []
    else
      [
        %{
          date: date,
          day_of_week: Date.day_of_week(date),
          month_view_says_bookable: month_says,
          per_day_has_slots: per_day_says,
          per_day_slot_count: length(slots),
          per_day_event_count: length(day_events)
        }
      ]
    end
  end

  defp print_report(result) do
    {start_date, end_date} = result.horizon

    IO.puts("\nAvailability audit for @#{result.username} (profile_id=#{result.profile_id})")
    IO.puts("  horizon: #{start_date} -> #{end_date} (#{result.checked_days} days)")
    IO.puts("  duration: #{result.duration_minutes} min")
    print_disagreements(result.disagreements)
  end

  defp print_disagreements([]) do
    IO.puts("  result: OK - no disagreements between month-view and per-day picker\n")
  end

  defp print_disagreements(list) do
    IO.puts("  result: MISMATCH - #{length(list)} disagreement(s):\n")
    Enum.each(list, &print_disagreement/1)
    IO.puts("")
  end

  defp print_disagreement(d) do
    direction = direction_label(d)

    IO.puts(
      "    #{d.date} (#{day_name(d.day_of_week)}): #{direction} (#{d.per_day_event_count} events)"
    )
  end

  defp direction_label(%{month_view_says_bookable: true, per_day_has_slots: false}) do
    "month says BOOKABLE but per-day has 0 slots -> empty-state risk"
  end

  defp direction_label(%{
         month_view_says_bookable: false,
         per_day_has_slots: true,
         per_day_slot_count: count
       }) do
    "month says UNAVAILABLE but per-day has #{count} slots -> hidden availability"
  end

  defp day_name(1), do: "Mon"
  defp day_name(2), do: "Tue"
  defp day_name(3), do: "Wed"
  defp day_name(4), do: "Thu"
  defp day_name(5), do: "Fri"
  defp day_name(6), do: "Sat"
  defp day_name(7), do: "Sun"
end
