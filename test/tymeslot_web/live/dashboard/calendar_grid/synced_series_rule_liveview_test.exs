defmodule TymeslotWeb.Dashboard.CalendarGrid.SyncedSeriesRuleLiveViewTest do
  @moduledoc """
  A series synced from Google or Outlook shows how it repeats when one of its
  occurrences is opened in the grid. Both providers list a series as its
  occurrences only, so the pattern comes from the series' master, read during
  the sync; the provider APIs are stubbed at their module seams.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Clock
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :set_mox_global
  setup :verify_on_exit!

  @weekday_tokens ~w(MO TU WE TH FR SA SU)
  @weekday_labels ~w(Mon Tue Wed Thu Fri Sat Sun)

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        google_sync_token: "valid-token"
      )

    %{conn: conn, integration: integration}
  end

  test "an occurrence of a synced Google series shows its repeat pattern", %{
    conn: conn,
    integration: integration
  } do
    start = DateTime.new!(Clock.utc_today(), ~T[10:00:00], "Etc/UTC")
    weekday = Date.day_of_week(start) - 1
    instance = instance(start)

    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: [instance], next_sync_token: "next"}}
    end)

    listing = fn _integration, _calendar, "master1", _from, _to -> {:ok, [instance]} end
    expect(GoogleCalendarAPIMock, :list_instances, listing)

    expect(GoogleCalendarAPIMock, :get_series_master, fn _integration, _calendar, "master1" ->
      {:ok,
       %{
         "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=#{Enum.at(@weekday_tokens, weekday)}"],
         "start" => %{"dateTime" => DateTime.to_iso8601(start)}
       }}
    end)

    assert :ok =
             perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    html = lv |> element("[id^='event-'][id*='-']", "Weekly standup") |> render_click()

    assert html =~ "Repeats weekly on #{Enum.at(@weekday_labels, weekday)}"
  end

  defp instance(start) do
    stamp = Calendar.strftime(start, "%Y%m%dT%H%M%SZ")

    %{
      "id" => "master1_#{stamp}",
      "iCalUID" => "master1@google.com",
      "recurringEventId" => "master1",
      "originalStartTime" => %{"dateTime" => DateTime.to_iso8601(start)},
      "status" => "confirmed",
      "summary" => "Weekly standup",
      "start" => %{"dateTime" => DateTime.to_iso8601(start)},
      "end" => %{"dateTime" => start |> DateTime.add(1800, :second) |> DateTime.to_iso8601()}
    }
  end
end
