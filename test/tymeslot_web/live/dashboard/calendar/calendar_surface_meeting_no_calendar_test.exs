defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMeetingNoCalendarTest do
  @moduledoc """
  The side panel's New event state for an organiser with no calendar to
  write to: a Tymeslot meeting can still be booked, kept in Tymeslot alone
  (its calendar is "None (Tymeslot only)"), while a plain event cannot be
  created and a note says why.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    Repo.delete!(context.integration)
    context
  end

  defp more_options(lv, extra \\ %{}) do
    lv
    |> element("#calendar-canvas")
    |> render_hook(
      "calendar:more_options",
      Map.merge(
        %{
          "draft" => "d1",
          "title" => "",
          "start" => "2026-10-15T13:00",
          "end" => "2026-10-15T14:00",
          "all_day" => false,
          "calendar" => nil,
          "location" => "",
          "guests" => ["ada@example.com"],
          "free" => false
        },
        extra
      )
    )

    assert_reply(lv, %{opened: true})
  end

  defp new_form(lv), do: form(lv, "#calendar-panel-new-form")

  test "a meeting is booked with no calendar, kept in Tymeslot alone", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv)

    render_change(new_form(lv), %{"meeting" => "true"})

    assert has_element?(lv, "#calendar-panel-calendar-none", "None (Tymeslot only)")
    assert has_element?(lv, "#calendar-panel-create:not([disabled])")

    render_submit(new_form(lv), %{"intent" => "create", "guest_name" => "Ada Lovelace"})

    meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: @task_timeout)

    assert meeting.organizer_user_id == user.id
    assert meeting.attendee_email == "ada@example.com"
    assert meeting.calendar_integration_id == nil

    eventually(fn -> render(lv) =~ "Meeting created and invitation sent" end,
      timeout: @task_timeout
    )

    refute has_element?(lv, "#calendar-panel")
  end

  test "a plain event cannot be created, and the note says why", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, %{"guests" => []})

    assert has_element?(
             lv,
             "#calendar-panel-calendar-note",
             "Connect a calendar to add events here."
           )

    assert has_element?(lv, "#calendar-panel-create[disabled]")

    # A submit that gets through anyway is refused, and nothing is written.
    render_submit(new_form(lv), %{"intent" => "create"})

    assert has_element?(lv, "#calendar-panel", "Choose one of your calendars.")
    assert Repo.all(MeetingSchema) == []
  end

  test "with only read-only calendars the note says they are read-only", %{
    conn: conn,
    user: user
  } do
    insert(:calendar_integration,
      user: user,
      name: "Holidays",
      provider: "ics_url",
      is_active: true,
      calendar_list: [%{"id" => "feed", "name" => "Public holidays", "selected" => true}]
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, %{"guests" => []})

    assert has_element?(
             lv,
             "#calendar-panel-calendar-note",
             "Your connected calendars are read-only, so events can't be added here."
           )
  end
end
