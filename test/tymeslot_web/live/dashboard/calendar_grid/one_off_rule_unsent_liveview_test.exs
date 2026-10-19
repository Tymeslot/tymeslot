defmodule TymeslotWeb.Dashboard.CalendarGrid.OneOffRuleUnsentLiveViewTest do
  @moduledoc """
  Giving a CalDAV one-off a repeat rule while the server cannot be reached.
  The edit is not queued for the next sync, which never replays a change
  to a series member, so the grid reports the failure and shows the event
  as it was rather than calling a series saved that the server never gets.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import TymeslotWeb.RepeatEditorHelpers
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers, only: [freeze_clock_midweek: 0]
  import Tymeslot.TestHelpers.Eventually

  alias Plug.Test
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Repo

  # Events are built from "today" and read in the organiser's zone, which is
  # not UTC: near midnight UTC on a Sunday, "today" is last week there.
  setup do: freeze_clock_midweek()

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    previous = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, :calendar_module, previous),
        else: Application.delete_env(:tymeslot, :calendar_module)
    end)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Europe/Berlin")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"]
      )

    start_at = DateTime.new!(Clock.utc_today(), ~T[09:00:00], "Etc/UTC")

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "planning",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/planning.ics",
        summary: "Planning",
        start_at: start_at,
        end_at: DateTime.add(start_at, 1, :hour),
        all_day: false,
        timezone: "Etc/UTC",
        sync_state: "synced"
      )

    stub(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 503, body: "", headers: %{}}}
    end)

    {:ok, conn: conn, event: event}
  end

  test "reports the failure and keeps the event a one-off", %{conn: conn, event: event} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
    |> element("#calendar-grid")
    |> render_repeat_save(%{
      "freq" => "weekly",
      "interval" => "1",
      "end_type" => "never"
    })

    eventually(fn -> render(lv) =~ "Failed to update event - changes reverted" end,
      timeout: 5_000
    )

    # The save the inline edit announced up front is withdrawn with the error.
    refute render(lv) =~ "Changes saved."

    stored = Repo.reload!(event)
    assert stored.sync_state == "synced"
    assert stored.recurrence_rule == nil
  end
end
