defmodule TymeslotWeb.Dashboard.MeetingSettings.SchedulingRulesLiveTest do
  @moduledoc """
  The scheduling rules section of the meeting type editor: a meeting type
  overrides its schedule's buffers, notice and booking window, and an empty
  field hands the rule back to the schedule.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :availability
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  setup :setup_dashboard_user

  setup %{user: user} do
    profile = Profiles.get_profile(user.id)

    default =
      case Schedules.get_default(profile.id) do
        nil ->
          {:ok, schedule} = Schedules.create_default(profile.id)
          schedule

        schedule ->
          schedule
      end

    {:ok, default} = Schedules.update_policy(default, %{buffer_before_minutes: 20})
    {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})
    {:ok, evenings} = Schedules.update_policy(evenings, %{buffer_before_minutes: 35})

    meeting_type = insert(:meeting_type, user: user, availability_schedule_id: nil)

    %{default: default, evenings: evenings, meeting_type: meeting_type}
  end

  @before "#meeting-type-scheduling-rules-buffer_before_minutes"

  defp open_editor(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp change_rule(view, field, value) do
    view
    |> element("#meeting-type-scheduling-rules-#{field}")
    |> render_change(%{"meeting_type" => %{field => value}})
  end

  test "each field names the value it inherits from the picked schedule", %{
    conn: conn,
    evenings: evenings,
    meeting_type: meeting_type
  } do
    view = open_editor(conn, meeting_type)

    assert has_element?(view, "#{@before}-hint", "Schedule: 20")

    view
    |> element("[phx-click='update_availability_schedule'][phx-value-schedule='#{evenings.id}']")
    |> render_click()

    assert has_element?(view, "#{@before}-hint", "Schedule: 35")
  end

  test "a value typed in is saved as this meeting type's own rule", %{
    conn: conn,
    user: user,
    meeting_type: meeting_type
  } do
    view = open_editor(conn, meeting_type)

    change_rule(view, "buffer_before_minutes", "0")

    saved = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
    assert saved.buffer_before_minutes == 0
    assert saved.min_advance_hours == nil
    assert has_element?(view, ~s|#{@before}[value="0"]|)
  end

  test "clearing a field hands the rule back to the schedule", %{
    conn: conn,
    user: user
  } do
    meeting_type = insert(:meeting_type, user: user, min_advance_hours: 48)
    view = open_editor(conn, meeting_type)

    assert has_element?(view, ~s|#meeting-type-scheduling-rules-min_advance_hours[value="48"]|)

    change_rule(view, "min_advance_hours", "")

    assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).min_advance_hours == nil
  end

  test "a value out of range is refused and left in the input with an error", %{
    conn: conn,
    user: user,
    meeting_type: meeting_type
  } do
    view = open_editor(conn, meeting_type)

    html = change_rule(view, "buffer_after_minutes", "500")

    assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).buffer_after_minutes == nil

    assert has_element?(
             view,
             ~s|#meeting-type-scheduling-rules-buffer_after_minutes[value="500"]|
           )

    assert html =~ "must be less than or equal to 120"
  end
end
