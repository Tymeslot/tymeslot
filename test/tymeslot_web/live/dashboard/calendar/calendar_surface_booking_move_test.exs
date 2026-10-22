defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceBookingMoveTest do
  @moduledoc """
  The preview's "Move booking to …", for a booking whose event the host
  moved in their own calendar: it shows only for a booking the Meetings page
  would offer to move, opens that page's dialog, and confirming moves the
  booking off the LiveView's process (`Tymeslot.CalendarGrid.WriteTask`),
  emails the attendee the new time, and leaves the preview showing the
  booking at that time with nothing more to move. A refusal says why and
  leaves the booking where it was.

  The hook's clicks are client-side, so the test pushes `calendar:open` as
  the hook does. The clock is frozen at 08:00 UTC on Wednesday 14 October
  2026 and the organiser is in London (UTC+1 that day).
  """

  # The move runs in a task off the LiveView, which reads and writes the
  # database and the frozen clock, both shared.
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @booked ~U[2026-10-15 13:00:00Z]
  @moved_to ~U[2026-10-15 15:00:00Z]

  setup %{conn: conn}, do: owner(conn)

  # A confirmed booking written to the organiser's calendar as `evt-1`,
  # flagged as moved there unless `attrs` say otherwise.
  defp booking(user, integration, attrs \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user: user,
          title: "Intro call with Anna Kowalski",
          meeting_type: "Intro call",
          attendee_name: "Anna Kowalski",
          attendee_email: "anna@example.com",
          start_time: @booked,
          end_time: DateTime.add(@booked, 30, :minute),
          status: "confirmed",
          calendar_sync_status: "externally_modified",
          calendar_integration_id: integration.id,
          provider_event_id: "evt-1"
        ],
        attrs
      )
    )
  end

  # The booking's calendar event, where the host moved it.
  defp moved_event(integration, start_at \\ @moved_to) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: "work",
      provider_event_id: "evt-1",
      summary: "Intro call with Anna Kowalski",
      start_at: start_at,
      end_at: DateTime.add(start_at, 30, :minute)
    )
  end

  defp open(lv, meeting) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:open", %{"id" => "booking-#{meeting.id}"})

    assert_reply(lv, %{opened: true})
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  describe "which bookings offer it" do
    test "a booking whose event was moved offers its calendar time beside the notice", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      meeting = booking(user, integration)
      moved_event(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, meeting)

      assert has_element?(
               lv,
               "#calendar-preview-moved",
               "This meeting's event was rescheduled in your external calendar."
             )

      # 15:00 UTC is 16:00 in London.
      assert has_element?(lv, "#calendar-preview-move", "Move booking to")
      assert has_element?(lv, "#calendar-preview-move", "16:00")
      # The booking's own actions stay beside it.
      assert has_element?(lv, "#calendar-preview-reschedule")
    end

    test "a booking nothing moved, one without a cached event, a dismissed one and a group meeting offer nothing",
         %{conn: conn, user: user, integration: integration} do
      unflagged = booking(user, integration, calendar_sync_status: nil)
      moved_event(integration)

      no_event =
        booking(user, integration,
          provider_event_id: "evt-gone",
          start_time: ~U[2026-10-15 09:00:00Z],
          end_time: ~U[2026-10-15 09:30:00Z]
        )

      dismissed =
        booking(user, integration,
          calendar_sync_status_dismissed_at: ~U[2026-10-14 07:00:00Z],
          start_time: ~U[2026-10-16 09:00:00Z],
          end_time: ~U[2026-10-16 09:30:00Z]
        )

      group =
        booking(user, integration,
          capacity: 4,
          start_time: ~U[2026-10-16 13:00:00Z],
          end_time: ~U[2026-10-16 13:30:00Z]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      for meeting <- [unflagged, no_event, dismissed, group] do
        open(lv, meeting)
        assert has_element?(lv, "#calendar-preview")
        refute has_element?(lv, "#calendar-preview-move")
        refute has_element?(lv, "#calendar-preview-moved")
      end
    end
  end

  describe "moving" do
    test "confirming moves the booking, emails the attendee and the preview shows the new time",
         %{conn: conn, user: user, integration: integration} do
      meeting = booking(user, integration)
      moved_event(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, meeting)
      lv |> element("#calendar-preview-move") |> render_click()

      # The Meetings page's dialog, in place of the preview.
      refute has_element?(lv, "#calendar-preview")
      assert has_element?(lv, "#calendar-move-booking", "Move booking to the new time")
      assert reload(meeting).start_time == @booked

      lv
      |> element("#calendar-move-booking [data-testid=confirm-calendar-move]")
      |> render_click()

      # Drawn at the new time at once, before the move answers.
      assert_push_event(lv, "calendar:events", %{events: events})
      assert Enum.any?(events, &(&1.id == "booking-#{meeting.id}" and &1.start =~ "16:00"))
      refute has_element?(lv, "#calendar-move-booking")

      eventually(fn -> assert render(lv) =~ "Booking moved to" end)

      moved = reload(meeting)
      assert moved.start_time == @moved_to
      assert moved.end_time == DateTime.add(@moved_to, 30, :minute)
      assert is_nil(moved.calendar_sync_status)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_emails", "meeting_id" => meeting.id}
      )

      open(lv, meeting)
      assert has_element?(lv, "#calendar-preview", "16:00")
      refute has_element?(lv, "#calendar-preview-move")
      refute has_element?(lv, "#calendar-preview-moved")
    end

    test "a move refused after the dialog opened says why and leaves the booking", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      meeting = booking(user, integration)
      moved_event(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, meeting)
      lv |> element("#calendar-preview-move") |> render_click()
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

      lv
      |> element("#calendar-move-booking [data-testid=confirm-calendar-move]")
      |> render_click()

      eventually(fn ->
        assert render(lv) =~
                 "Tymeslot is still updating your calendar for this booking. Please try again in a moment."
      end)

      unchanged = reload(meeting)
      assert unchanged.start_time == @booked
      assert unchanged.calendar_sync_status == "externally_modified"
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})
    end

    test "a calendar time changed while the dialog was open is offered again, not applied", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      meeting = booking(user, integration)
      event = moved_event(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, meeting)
      lv |> element("#calendar-preview-move") |> render_click()

      # The cached times are stored to the microsecond.
      later = %{DateTime.add(@moved_to, 1, :hour) | microsecond: {0, 6}}

      event
      |> Changeset.change(start_at: later, end_at: DateTime.add(later, 30, :minute))
      |> Repo.update!()

      lv
      |> element("#calendar-move-booking [data-testid=confirm-calendar-move]")
      |> render_click()

      eventually(fn -> assert render(lv) =~ "The meeting has moved again in your calendar." end)
      # The dialog is back with the new time (17:00 in London).
      assert has_element?(lv, "#calendar-move-booking", "17:00")
      assert reload(meeting).start_time == @booked
    end

    test "a stranger's booking id opens nothing", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      other = insert(:user)

      theirs =
        booking(other, insert(:calendar_integration, user: other),
          organizer_email: "x@example.com"
        )

      _mine = booking(user, integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-canvas") |> render_hook("booking:move", %{"id" => theirs.id})

      refute has_element?(lv, "#calendar-move-booking")
      assert reload(theirs).start_time == @booked
    end
  end
end
