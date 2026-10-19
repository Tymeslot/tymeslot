defmodule Tymeslot.Availability.Audit do
  @moduledoc """
  On-demand diagnostic that compares the booking page's month view
  (`Offer.days_in_range/4`) against its time picker (`Offer.slots_for_date/3`)
  for a profile, reporting any day the month view marks bookable that offers
  no time, or the other way round.

  It asks `Offer` exactly what a visitor's page asks, with the profile's own
  timezone as the visitor's, so it checks what the page offers rather than a
  copy of the engine's inputs: the host's calendars and their live bookings
  both count. The two answers must agree, so a non-empty `:disagreements`
  list indicates a regression or a data-state edge case worth investigating.

  The host's cached availability is dropped first, so the audit reads the
  calendars once, now, and both answers are folded from that one read.

  Intended for manual investigation in `bin/tymeslot remote` when a user
  reports unexpected availability:

      iex> Tymeslot.Availability.Audit.run("alice")

  Returns `{:ok, result}` with the full audit data; prints a human-readable
  report to stdout by default. Pass `print: false` to suppress.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.AvailabilityScheduleQueries
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Clock
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries

  @default_duration_minutes 30
  @default_horizon_days 30

  @type disagreement :: %{
          required(:date) => Date.t(),
          required(:day_of_week) => 1..7,
          required(:month_view_says_bookable) => boolean(),
          required(:per_day_has_slots) => boolean(),
          required(:per_day_slot_count) => non_neg_integer()
        }

  @type result :: %{
          required(:profile_id) => pos_integer(),
          required(:schedule_id) => pos_integer() | nil,
          required(:username) => String.t() | nil,
          required(:horizon) => {Date.t(), Date.t()},
          required(:duration_minutes) => pos_integer(),
          required(:checked_days) => pos_integer(),
          required(:disagreements) => [disagreement()]
        }

  @doc """
  Audits a profile by username. Returns `{:ok, result}` on success,
  `{:error, :not_found}` if no profile exists for that username, and the
  booking page's own error when the host's calendars cannot be read.

  Prints a human-readable summary to stdout unless `print: false`.

  ## Options

    * `:duration_minutes` — meeting duration in minutes (default `30`)
    * `:horizon_days` — how far ahead to check from `:start_date` (default `30`)
    * `:start_date` — first date to audit (default today UTC)
    * `:print` — set to `false` to suppress IO (default `true`)
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(username, opts \\ []) do
    with {:ok, profile} <- profile(username),
         {:ok, result} <- audit(profile, opts) do
      if Keyword.get(opts, :print, true), do: print_report(result)
      {:ok, result}
    end
  end

  @doc """
  Same as `run/2` but takes an already-loaded profile schema. Never prints.
  """
  @spec audit(map(), keyword()) :: {:ok, result()} | {:error, term()}
  def audit(profile, opts \\ []) do
    duration_minutes = Keyword.get(opts, :duration_minutes, @default_duration_minutes)
    horizon_days = Keyword.get(opts, :horizon_days, @default_horizon_days)
    start_date = Keyword.get(opts, :start_date, Clock.utc_today())
    end_date = Date.add(start_date, horizon_days)
    request = %{profile: profile, user_timezone: Profiles.timezone(profile)}

    Availability.changed(profile.user_id)

    with {:ok, month_view} <- Offer.days_in_range(request, start_date, end_date, duration_minutes),
         {:ok, disagreements} <-
           disagreements(request, month_view, Date.range(start_date, end_date), duration_minutes) do
      {:ok,
       %{
         profile_id: profile.id,
         schedule_id: default_schedule_id(profile),
         username: profile.username,
         horizon: {start_date, end_date},
         duration_minutes: duration_minutes,
         checked_days: Date.diff(end_date, start_date) + 1,
         disagreements: disagreements
       }}
    end
  end

  defp profile(username) do
    case ProfileQueries.get_by_username_with_user(username) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # The schedule a booking page with no meeting type chosen reads, reported so
  # that a database which has lost it shows as `nil` rather than going unseen.
  defp default_schedule_id(profile) do
    case AvailabilityScheduleQueries.get_default(profile.id) do
      %{id: id} -> id
      nil -> nil
    end
  end

  defp disagreements(request, month_view, dates, duration_minutes) do
    found =
      Enum.reduce_while(dates, {:ok, []}, fn date, {:ok, found} ->
        case compare_one_date(request, date, month_view, duration_minutes) do
          {:ok, disagreement} -> {:cont, {:ok, disagreement ++ found}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, found} <- found, do: {:ok, Enum.reverse(found)}
  end

  defp compare_one_date(request, date, month_view, duration_minutes) do
    month_says = Map.get(month_view, Date.to_iso8601(date), false)

    with {:ok, slots} <- Offer.slots_for_date(request, Date.to_iso8601(date), duration_minutes) do
      per_day_says = slots != []

      if month_says == per_day_says do
        {:ok, []}
      else
        {:ok,
         [
           %{
             date: date,
             day_of_week: Date.day_of_week(date),
             month_view_says_bookable: month_says,
             per_day_has_slots: per_day_says,
             per_day_slot_count: length(slots)
           }
         ]}
      end
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

    IO.puts("    #{d.date} (#{day_name(d.day_of_week)}): #{direction}")
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
