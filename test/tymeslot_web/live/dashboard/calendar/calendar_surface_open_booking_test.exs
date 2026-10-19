defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceOpenBookingTest do
  @moduledoc """
  Quick create's "Open for booking" on the new calendar: the settings name
  the meeting types that can be opened, a slot opens just this once (a date
  override) or every week (the weekday's hours), the toast names the hours
  that result, and Undo puts the old ones back. Refusals answer in the reply
  and write nothing.

  Monday 19 October is open 09:00 to 17:00 every week; the frozen clock is
  Wednesday 14 October, 09:00 in London.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Dashboard.Calendar.ClientStrings

  setup %{conn: conn} do
    context = owner(conn)
    # The bookable layer reloads after each opening and reads the calendars.
    TestMocks.stub_no_calendar_events()
    profile = Repo.get_by!(ProfileSchema, user_id: context.user.id)
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    insert(:weekly_availability,
      schedule: schedule,
      day_of_week: 1,
      is_available: true,
      start_time: ~T[09:00:00],
      end_time: ~T[17:00:00]
    )

    intro =
      insert(:meeting_type,
        user: context.user,
        name: "Intro call",
        duration_minutes: 30,
        sort_order: 1
      )

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
    Map.merge(context, %{lv: lv, schedule: schedule, intro: intro})
  end

  defp evening(meeting_type, changes \\ %{}) do
    Map.merge(
      %{
        "draft" => "d1",
        "meeting_type" => meeting_type.id,
        "start" => "2026-10-19T17:00",
        "end" => "2026-10-19T18:30",
        "repeat" => "once"
      },
      changes
    )
  end

  defp open_booking(lv, params),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:open_booking", params)

  defp override(schedule, date \\ ~D[2026-10-19]),
    do: AvailabilityOverrideQueries.get_override_by_schedule_and_date(schedule.id, date)

  defp monday(schedule), do: WeeklySchedule.get_day_availability(schedule.id, 1)

  describe "what the hook is given" do
    test "the meeting types that can be opened, active and unarchived only", %{
      conn: conn,
      user: user,
      intro: intro
    } do
      insert(:meeting_type, user: user, name: "Paused", is_active: false)
      insert(:meeting_type, user: user, name: "Old", is_archived: true)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

      assert_reply(lv, %{
        settings: %{meeting_types: [%{id: id, name: "Intro call", duration: 30}]}
      })

      assert id == intro.id
    end

    test "every word the opening shows" do
      strings = ClientStrings.build("en")

      keys =
        ~w(kind_label kind_event kind_open meeting_type_chip repeat_label just_this_once every_week open_save open_hint open_draft_title open_refused open_unconfirmed)a

      assert keys -- Map.keys(strings) == []
      assert strings.kind_open == "Open for booking"
      assert strings.open_draft_title == "Open for %{name}"
    end
  end

  describe "just this once" do
    test "widens that day's hours to cover the slot and says what is open", %{
      lv: lv,
      intro: intro,
      schedule: schedule
    } do
      open_booking(lv, evening(intro))

      assert_reply(lv, %{accepted: true})

      assert %{override_type: "custom_hours", start_time: ~T[09:00:00], end_time: ~T[18:30:00]} =
               override(schedule)

      assert %{start_time: ~T[09:00:00], end_time: ~T[17:00:00]} = monday(schedule)

      assert has_element?(
               lv,
               "#calendar-toast",
               "Open for Intro call on Mon 19 Oct, 09:00 to 18:30"
             )

      assert has_element?(lv, "#calendar-undo")
      assert_push_event(lv, "calendar:create-settled", %{draft: "d1"})
    end

    test "undo puts the day back as it was", %{lv: lv, intro: intro, schedule: schedule} do
      open_booking(lv, evening(intro))
      assert_reply(lv, %{accepted: true})

      lv |> element("#calendar-undo") |> render_click()

      assert override(schedule) == nil
      assert has_element?(lv, "#calendar-toast", "Bookable times for Intro call put back.")
      refute has_element?(lv, "#calendar-undo")
    end

    test "the same draft sent again opens nothing more", %{
      lv: lv,
      intro: intro,
      schedule: schedule
    } do
      open_booking(lv, evening(intro))
      assert_reply(lv, %{accepted: true})
      lv |> element(~s(#calendar-toast button[aria-label="Dismiss"])) |> render_click()

      open_booking(lv, evening(intro, %{"end" => "2026-10-19T20:00"}))

      assert_reply(lv, %{accepted: true})
      assert %{end_time: ~T[18:30:00]} = override(schedule)
      refute has_element?(lv, "#calendar-toast")
    end
  end

  describe "every week" do
    test "widens the weekday's hours and says so", %{lv: lv, intro: intro, schedule: schedule} do
      open_booking(lv, evening(intro, %{"repeat" => "weekly"}))

      assert_reply(lv, %{accepted: true})

      assert %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[18:30:00]} =
               monday(schedule)

      assert override(schedule) == nil

      assert has_element?(
               lv,
               "#calendar-toast",
               "Open for Intro call every Monday, 09:00 to 18:30"
             )
    end

    test "undo puts the old weekly hours back", %{lv: lv, intro: intro, schedule: schedule} do
      open_booking(lv, evening(intro, %{"repeat" => "weekly"}))
      assert_reply(lv, %{accepted: true})

      lv |> element("#calendar-undo") |> render_click()

      assert %{start_time: ~T[09:00:00], end_time: ~T[17:00:00]} = monday(schedule)
    end
  end

  describe "refusals write nothing" do
    test "another organiser's meeting type", %{lv: lv, schedule: schedule} do
      theirs = insert(:meeting_type, name: "Theirs")

      open_booking(lv, evening(theirs))

      assert_reply(lv, %{
        accepted: false,
        field: "meeting_type",
        error: "That meeting type can't be opened. Choose another one."
      })

      assert override(schedule) == nil
    end

    test "a time that has passed", %{lv: lv, intro: intro, schedule: schedule} do
      open_booking(
        lv,
        evening(intro, %{"start" => "2026-10-12T17:00", "end" => "2026-10-12T18:00"})
      )

      assert_reply(lv, %{
        accepted: false,
        field: "start",
        error: "That time has passed. Choose a later one."
      })

      assert override(schedule, ~D[2026-10-12]) == nil
    end

    test "an end before the start", %{lv: lv, intro: intro, schedule: schedule} do
      open_booking(lv, evening(intro, %{"end" => "2026-10-19T16:00"}))

      assert_reply(lv, %{
        accepted: false,
        field: "end",
        error: "The time must end after it starts."
      })

      assert override(schedule) == nil
    end

    test "the edit rate limit", %{lv: lv, user: user, intro: intro, schedule: schedule} do
      for _i <- 1..30, do: RateLimiter.check(:calendar_event_edit, user.id)

      open_booking(lv, evening(intro))

      assert_reply(lv, %{
        accepted: false,
        field: nil,
        error: "Too many edits. Please wait a moment."
      })

      assert override(schedule) == nil
    end

    test "params the hook could not have sent", %{lv: lv, intro: intro, schedule: schedule} do
      for params <- [
            evening(intro, %{"draft" => "not a draft"}),
            Map.delete(evening(intro), "draft"),
            evening(intro, %{"repeat" => "daily"}),
            evening(intro, %{"meeting_type" => "intro"}),
            evening(intro, %{"start" => "soon"})
          ] do
        open_booking(lv, params)
        assert_reply(lv, %{accepted: false})
      end

      assert override(schedule) == nil
      assert %{end_time: ~T[17:00:00]} = monday(schedule)
    end
  end
end
