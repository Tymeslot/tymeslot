defmodule TymeslotWeb.Dashboard.CalendarGrid.UndeliveredUpdatesLiveviewTest do
  @moduledoc """
  The notice in an event's details naming the guests whose latest update
  email could not be delivered, and its Dismiss action.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.CalendarGrid.UndeliveredUpdates

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    integration = insert(:calendar_integration, user: user, is_active: true)

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Planning",
        attendees: [
          %{"email" => "missed@example.com", "name" => "Missed"},
          %{"email" => "reached@example.com", "name" => "Reached"}
        ],
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false,
        synced_at: DateTime.utc_now(:second)
      )

    {:ok, conn: conn, user: user, integration: integration, event: event}
  end

  test "names the guests the latest update could not reach, and Dismiss clears them", %{
    conn: conn,
    user: user,
    integration: integration,
    event: event
  } do
    UndeliveredUpdates.note_delivery(
      integration.id,
      event.uid,
      "missed@example.com",
      {:error, :smtp_down}
    )

    UndeliveredUpdates.note_delivery(
      integration.id,
      event.uid,
      "reached@example.com",
      {:ok, "sent"}
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("[id^='event-#{event.id}-']") |> render_click()

    notice = lv |> element("#undelivered-updates-notice") |> render()
    assert notice =~ "missed@example.com"
    refute notice =~ "reached@example.com"

    lv |> element("#undelivered-updates-notice button", "Dismiss") |> render_click()

    refute has_element?(lv, "#undelivered-updates-notice")
    assert UndeliveredUpdates.list_for_event(user.id, integration.id, event.uid) == []
  end

  test "shows no notice for an event whose update reached everyone", %{
    conn: conn,
    event: event
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("[id^='event-#{event.id}-']") |> render_click()

    assert has_element?(lv, "#event-detail-modal")
    refute has_element?(lv, "#undelivered-updates-notice")
  end
end
