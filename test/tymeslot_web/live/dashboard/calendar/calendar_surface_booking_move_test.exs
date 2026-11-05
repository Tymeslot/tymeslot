defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceBookingMoveTest do
  @moduledoc """
  The preview's "Move booking to …", for a booking whose event the host
  moved in their own calendar: it shows only for a booking the Meetings page
  would offer to move, opens that page's dialog, and confirming moves the
  booking off the LiveView's process (`Tymeslot.CalendarGrid.WriteTask`),
  emails the attendee the new time, and leaves the preview showing the
  booking at that time with nothing more to move. A refusal, a crash or the
  rate limit says why and leaves the booking where it was, and an answer
  never takes over a dialog opened since.

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
  alias Ecto.UUID
  alias Phoenix.LiveView.Socket
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Dashboard.Calendar.BookingMove

  @booked ~U[2026-10-15 13:00:00Z]
  @moved_to ~U[2026-10-15 15:00:00Z]
  @push_timeout 2_000

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
  defp moved_event(integration, start_at \\ @moved_to, event_id \\ "evt-1") do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: "work",
      provider_event_id: event_id,
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

  defp confirm(lv),
    do:
      lv
      |> element("#calendar-move-booking [data-testid=confirm-calendar-move]")
      |> render_click()

  defp reschedule_emails,
    do: all_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})

  # The next `calendar:events` push whose events satisfy `wanted?`; earlier
  # pushes (the window as it was before the step) are skipped.
  defp await_events(lv, wanted?, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @push_timeout
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    assert_push_event(lv, "calendar:events", %{events: events}, remaining)

    if wanted?.(events), do: events, else: await_events(lv, wanted?, deadline)
  end

  defp starts_at?(events, meeting, clock),
    do: Enum.any?(events, &(&1.id == "booking-#{meeting.id}" and &1.start =~ "T#{clock}"))

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

      # Drawn at the new time at once, then back at 14:00 London once refused.
      await_events(lv, &starts_at?(&1, meeting, "16:00"))
      await_events(lv, &starts_at?(&1, meeting, "14:00"))

      unchanged = reload(meeting)
      assert unchanged.start_time == @booked
      assert unchanged.calendar_sync_status == :externally_modified
      assert reschedule_emails() == []
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

    test "a stranger's booking id opens nothing and moves nothing", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      other = insert(:user)
      their_integration = insert(:calendar_integration, user: other)
      # Movable for its own organiser: flagged, with its event moved.
      theirs = booking(other, their_integration, organizer_email: "x@example.com")
      moved_event(their_integration)
      _mine = booking(user, integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-canvas") |> render_hook("booking:move", %{"id" => theirs.id})
      lv |> element("#calendar-canvas") |> render_hook("booking:confirm_move", %{})

      eventually(fn ->
        assert render(lv) =~ "This booking can no longer be moved to its calendar time."
      end)

      refute has_element?(lv, "#calendar-move-booking")
      assert reload(theirs).start_time == @booked
      assert reschedule_emails() == []
    end

    test "confirming twice moves the booking once", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      meeting = booking(user, integration)
      moved_event(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, meeting)
      lv |> element("#calendar-preview-move") |> render_click()
      lv |> element("#calendar-canvas") |> render_hook("booking:confirm_move", %{})
      lv |> element("#calendar-canvas") |> render_hook("booking:confirm_move", %{})

      eventually(fn -> assert render(lv) =~ "Booking moved to" end)
      assert reload(meeting).start_time == @moved_to
      assert [_one] = reschedule_emails()
    end

    test "a move that crashes says it could not move, redraws the old time and frees the button",
         %{conn: conn, user: user, integration: integration} do
      meeting = booking(user, integration)
      moved_event(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, meeting)
      lv |> element("#calendar-preview-move") |> render_click()
      # The real move is refused (another booking starts at the new time),
      # so the booking stays put whichever answer lands first.
      booking(user, integration,
        calendar_sync_status: nil,
        provider_event_id: "evt-other",
        start_time: @moved_to,
        end_time: DateTime.add(@moved_to, 30, :minute)
      )

      confirm(lv)

      # What `WriteTask` sends when the move raises (`WriteTaskTest` covers
      # the raise itself). It and the real answer may land in either order.
      send(lv.pid, {:booking_move_result, meeting.id, {:error, :failed_to_update_meeting}})

      # Each answer reloads the window with the booking back at 14:00.
      await_events(
        lv,
        &(starts_at?(&1, meeting, "14:00") and not starts_at?(&1, meeting, "16:00"))
      )

      await_events(lv, &starts_at?(&1, meeting, "14:00"))

      assert render(lv) =~ "Tymeslot could not move this booking."
      assert reload(meeting).start_time == @booked

      open(lv, meeting)
      assert has_element?(lv, "#calendar-preview-move:not([disabled])")
      refute has_element?(lv, "#calendar-preview-move", "Moving…")
    end

    test "a confirm past the rate limit is refused with the limiter's message and moves nothing",
         %{conn: conn, user: user, integration: integration} do
      meeting = booking(user, integration)
      moved_event(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, meeting)
      lv |> element("#calendar-preview-move") |> render_click()

      {:error, :rate_limited, message} =
        Enum.find(
          Stream.repeatedly(fn -> RateLimiter.check(:dashboard_reschedule, user.id) end),
          &match?({:error, :rate_limited, _message}, &1)
        )

      confirm(lv)

      eventually(fn -> assert render(lv) =~ String.replace(message, "'", "&#39;") end)
      # The dialog stays for another try.
      assert has_element?(lv, "#calendar-move-booking")
      assert reload(meeting).start_time == @booked
      assert reschedule_emails() == []
    end
  end

  describe "an answer arriving while another dialog is open" do
    setup %{user: user, integration: integration} do
      a = booking(user, integration)
      moved_event(integration)

      b =
        booking(user, integration,
          attendee_name: "Ben Ortiz",
          title: "Intro call with Ben Ortiz",
          provider_event_id: "evt-2",
          start_time: ~U[2026-10-16 13:00:00Z],
          end_time: ~U[2026-10-16 13:30:00Z]
        )

      moved_event(integration, ~U[2026-10-16 15:00:00Z], "evt-2")
      %{a: a, b: b}
    end

    defp open_move(lv, meeting) do
      open(lv, meeting)
      lv |> element("#calendar-preview-move") |> render_click()
      assert has_element?(lv, "#calendar-move-booking")
    end

    test "A moving or refused leaves B's dialog open, on B", %{conn: conn, a: a, b: b} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_move(lv, b)

      send(lv.pid, {:booking_move_result, a.id, {:ok, reload(a)}})
      send(lv.pid, {:booking_move_result, a.id, {:error, :failed_to_update_meeting}})
      eventually(fn -> assert render(lv) =~ "Tymeslot could not move this booking." end)

      assert has_element?(lv, "#calendar-move-booking", "Ben Ortiz")
    end

    test "A's time changing again keeps B's dialog on B, and confirming moves B", %{
      conn: conn,
      a: a,
      b: b
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_move(lv, b)

      send(lv.pid, {:booking_move_result, a.id, {:error, :offer_changed}})
      eventually(fn -> assert render(lv) =~ "The meeting has moved again in your calendar." end)

      assert has_element?(lv, "#calendar-move-booking", "Ben Ortiz")
      refute has_element?(lv, "#calendar-move-booking", "Anna Kowalski")

      confirm(lv)
      eventually(fn -> assert render(lv) =~ "Booking moved to" end)
      assert reload(b).start_time == ~U[2026-10-16 15:00:00Z]
      assert reload(a).start_time == @booked
    end
  end

  describe "an answer reaching a surface with no window loaded" do
    test "is flashed and frees the booking, with nothing reloaded", %{user: user} do
      id = UUID.generate()

      socket = %Socket{
        assigns: %{
          __changed__: %{},
          ready?: false,
          current_user: user,
          profile: nil,
          time_format: "24h",
          moving_booking: MapSet.new([id])
        }
      }

      socket = BookingMove.settled(socket, id, {:error, :slot_taken})

      assert socket.assigns.moving_booking == MapSet.new()

      assert_received {:flash,
                       {:error,
                        "Tymeslot could not move this booking. Another booking already starts at that time."}}
    end
  end
end
