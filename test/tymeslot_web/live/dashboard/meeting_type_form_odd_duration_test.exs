defmodule TymeslotWeb.Dashboard.MeetingTypeFormOddDurationTest do
  @moduledoc """
  A meeting type stored with a duration off the five-minute step, written
  before the step rule existed or by another path, can still be edited from
  the dashboard.

  The form always posts the duration, pre-filled with the stored value, so a
  step check on every save refused an edit to the name alone until the host
  also changed the length. The step holds only for a duration that changes.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  setup %{user: user} do
    %{meeting_type: insert(:meeting_type, user: user, name: "Check-in", duration_minutes: 7)}
  end

  defp open_edit_form(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp change(view, params) do
    view
    |> element(~s|input[name="meeting_type[name]"]|)
    |> render_change(%{"meeting_type" => params})
  end

  test "an edit to the name alone saves, keeping the stored length",
       %{conn: conn, user: user, meeting_type: meeting_type} do
    view = open_edit_form(conn, meeting_type)

    html = change(view, %{"name" => "Quick check-in"})

    refute html =~ "Duration must be a multiple of"

    stored = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
    assert stored.name == "Quick check-in"
    assert stored.duration_minutes == 7
  end

  test "a new length off the step is still refused",
       %{conn: conn, user: user, meeting_type: meeting_type} do
    view = open_edit_form(conn, meeting_type)

    view
    |> element(~s|input[name="meeting_type[duration]"]|)
    |> render_change(%{"meeting_type" => %{"duration" => "8"}})

    assert render(view) =~ "Duration must be a multiple of 5 minutes"
    assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).duration_minutes == 7
  end

  # The instant feedback applies the rule saving does: changing the length
  # away and back to the stored one clears the error rather than leaving a
  # message about a length saving accepts. A successful autosave resets the
  # errors by itself, so the name is left invalid to keep every save refused
  # and the field feedback the only thing on screen.
  test "changing the length off the step and back to the stored one clears the error",
       %{conn: conn, user: user, meeting_type: meeting_type} do
    view = open_edit_form(conn, meeting_type)
    duration = element(view, ~s|input[name="meeting_type[duration]"]|)

    change(view, %{"name" => ""})
    render_change(duration, %{"meeting_type" => %{"duration" => "8"}})
    assert render(view) =~ "Duration must be a multiple of 5 minutes"

    html = render_change(duration, %{"meeting_type" => %{"duration" => "7"}})
    refute html =~ "Duration must be a multiple of"
    assert html =~ "Meeting name is required"

    assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).duration_minutes == 7
  end
end
