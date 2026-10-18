defmodule TymeslotWeb.CalendarSurfaceHelpers do
  @moduledoc """
  An organiser for the redesigned calendar's LiveView tests: switched on to
  the new surface (unless told otherwise), clock on 24 hours, zone London,
  with one Google account holding a "Work" and a "Family" calendar.

  The clock is frozen at 08:00 UTC on Wednesday 14 October 2026 (09:00 in
  London), so "this week" is 12 to 18 October in every test that does not
  name a date. The frozen clock reaches the LiveView through `$callers`.
  """

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Conn
  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Test.ClockHelpers

  @now ~U[2026-10-14 08:00:00.000000Z]

  @doc "The frozen instant."
  @spec now() :: DateTime.t()
  def now, do: @now

  @doc """
  Signs in a new organiser. Options: `redesign_enabled` (default `true`),
  `timezone` (default `"Europe/London"`), `preferences` (a keyword list
  merged into the stored calendar preferences).
  """
  @spec owner(Conn.t(), keyword()) :: %{conn: Conn.t(), user: map(), integration: map()}
  def owner(conn, opts \\ []) do
    ClockHelpers.freeze_clock(@now)

    user = insert(:user, onboarding_completed_at: @now)
    insert(:profile, user: user, timezone: Keyword.get(opts, :timezone, "Europe/London"))

    preferences =
      Map.merge(
        %{redesign_enabled: Keyword.get(opts, :redesign_enabled, true), time_format: "24h"},
        Map.new(Keyword.get(opts, :preferences, []))
      )

    {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, preferences)

    integration =
      insert(:calendar_integration,
        user: user,
        name: "Work account",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "family", "name" => "Family", "selected" => true}
        ]
      )

    conn =
      conn
      |> Test.init_test_session(%{})
      |> Conn.fetch_session()
      |> log_in_user(user)

    %{conn: conn, user: user, integration: integration}
  end

  @doc "A synced, timed event on one of `integration`'s calendars."
  @spec event(map(), String.t(), String.t(), DateTime.t(), pos_integer(), keyword()) :: map()
  def event(integration, calendar_id, summary, start_at, minutes \\ 60, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          provider: "google",
          provider_calendar_id: calendar_id,
          summary: summary,
          start_at: start_at,
          end_at: DateTime.add(start_at, minutes, :minute),
          all_day: false,
          sync_state: "synced"
        ],
        attrs
      )
    )
  end
end
