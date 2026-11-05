defmodule TymeslotWeb.Dashboard.MeetingTypeHandSentEventsLiveTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  # Meeting type ids arrive as client strings; an event sent by hand with
  # anything else is ignored rather than crashing the dashboard.
  test "a non-numeric id is ignored rather than crashing the dashboard", %{
    conn: conn,
    user: user
  } do
    type = insert(:meeting_type, user: user, name: "Strategy Session", is_private: false)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    target = with_target(view, "#meeting_settings")

    for event <- ~w(edit_type duplicate_type toggle_type show_delete_modal) do
      render_click(target, event, %{"id" => "not-an-id"})
    end

    render_click(target, "toggle_private", %{"id" => "1x", "listed" => "false"})

    render_click(target, "toggle_page_membership", %{
      "id" => "",
      "page" => "1",
      "listed" => "true"
    })

    assert render(view) =~ "Strategy Session"
    refute MeetingTypes.get_meeting_type(type.id, user.id).is_private
  end

  test "a visibility switch sent without a state it can read is ignored", %{
    conn: conn,
    user: user
  } do
    type = insert(:meeting_type, user: user, name: "Strategy Session", is_private: false)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    target = with_target(view, "#meeting_settings")
    id = to_string(type.id)

    render_click(target, "toggle_private", %{"id" => id})
    render_click(target, "toggle_private", %{"id" => id, "listed" => "maybe"})
    render_click(target, "toggle_page_membership", %{"id" => id, "listed" => "true"})

    render_click(target, "toggle_page_membership", %{
      "id" => id,
      "page" => %{"x" => "1"},
      "listed" => "true"
    })

    assert render(view) =~ "Strategy Session"
    refute MeetingTypes.get_meeting_type(type.id, user.id).is_private
  end
end
