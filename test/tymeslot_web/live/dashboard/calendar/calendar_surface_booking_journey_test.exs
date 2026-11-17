defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceBookingJourneyTest do
  @moduledoc """
  The calendar as the place an organiser shapes their booking page. Opening
  an evening for booking from quick create puts those times on the booking
  page for that date (and Every week for every such weekday), the layer
  redraws to match, and Undo takes them off again. A booking request on the
  grid stands out, opens to Accept and Decline, and Accept confirms it and
  hands it to the ordinary confirmation emails; an expired request opens to
  a quiet line instead of actions.

  The hook's clicks are client-side, so the test pushes the events the hook
  pushes (`calendar:open_booking`, `calendar:open`, `calendar:undo`) and
  reads what the organiser would see: the toast, the preview, the flash and
  the `calendar:events` and `calendar:bookable` pushes. The booking page is
  read through `Offer.slots_for_date/3` and `Offer.slots_for_range/4`, which
  its day and week views render from.

  The clock is frozen at 09:00 London time on Wednesday 14 October 2026; the
  organiser is open 09:00 to 17:00 Monday to Friday with no buffers and no
  notice. `async: false`: the accept journey uses the real email service and
  Swoosh's shared test process, both global.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers, only: [offered: 4]
  import Tymeslot.Factory

  import TymeslotWeb.BookableLayerHelpers,
    only: [await_bookable: 2, meeting_type: 2, open_days: 2]

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @push_timeout 2_000

  setup %{conn: conn} do
    AvailabilityCache.clear_all()

    # `owner/2` stubs the provider fetch to "no events", so the organiser's
    # calendar holds nothing busy at the provider.
    context = owner(conn)
    %{profile: profile, schedule: schedule} = open_days(context.user, [1, 2, 3, 4, 5])
    intro = meeting_type(context.user, slug: "intro-call", is_active: true)

    Map.merge(context, %{profile: profile, schedule: schedule, meeting_type: intro})
  end

  defp hook(lv, name, params),
    do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp has_window?(payload, from, to),
    do: Enum.any?(payload.windows, &(&1.start == from and &1.end == to))

  # The canvas asks for its first window with `calendar:ready` and gets it as
  # the reply, not as a push.
  defp ready_events(lv) do
    hook(lv, "calendar:ready", %{})
    assert_reply(lv, %{events: events})
    events
  end

  # The next `calendar:events` push whose events satisfy `wanted?`; earlier
  # pushes (the window as it was before the step) are skipped.
  defp await_events(lv, wanted?, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @push_timeout
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    assert_push_event(lv, "calendar:events", %{events: events}, remaining)

    if wanted?.(events), do: events, else: await_events(lv, wanted?, deadline)
  end

  # The request the booking page builds for a guest in London.
  defp request(profile, meeting_type),
    do: %{profile: profile, user_timezone: "Europe/London", meeting_type: meeting_type}

  # The week view's answer for one day.
  defp week_slots(profile, meeting_type, date) do
    {:ok, by_day} = Offer.slots_for_range(request(profile, meeting_type), date, date, 30)
    Map.fetch!(by_day, Date.to_iso8601(date))
  end

  defp guest_sees?(profile, meeting_type, date, label) do
    AvailabilityCache.clear_all()
    day = offered(profile, date, 30, meeting_type: meeting_type, timezone: "Europe/London")
    week = week_slots(profile, meeting_type, date)

    # The two views must agree before either is believed.
    assert day == week
    label in day
  end

  describe "open for booking" do
    test "just this once puts the evening on the booking page and Undo takes it off", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type
    } do
      thursday = ~D[2026-10-15]

      # Before: the guest can book Thursday until 16:30, nothing in the evening.
      assert guest_sees?(profile, meeting_type, thursday, "4:30 PM")
      refute guest_sees?(profile, meeting_type, thursday, "6:00 PM")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # The layer draws Thursday's usual hours.
      assert await_bookable(lv, &has_window?(&1, "2026-10-15T09:00", "2026-10-15T17:00")).on

      # 1. Open 17:30 to 18:30 just this once from quick create.
      hook(lv, "calendar:open_booking", %{
        "meeting_type" => to_string(meeting_type.id),
        "start" => "2026-10-15T17:30",
        "end" => "2026-10-15T18:30",
        "repeat" => "once",
        "draft" => "d1"
      })

      assert_reply(lv, %{accepted: true})

      # The toast names the day's resulting hours, with Undo.
      assert has_element?(
               lv,
               "#calendar-toast",
               "Open for Intro call on Thu 15 Oct, 09:00 to 18:30"
             )

      assert has_element?(lv, "#calendar-undo")

      # 2. The availability broadcast redraws Thursday as one window to 18:30.
      await_bookable(lv, &has_window?(&1, "2026-10-15T09:00", "2026-10-15T18:30"))

      # 3. The booking page now offers the evening on that date only.
      assert guest_sees?(profile, meeting_type, thursday, "5:30 PM")
      assert guest_sees?(profile, meeting_type, thursday, "6:00 PM")
      refute guest_sees?(profile, meeting_type, ~D[2026-10-22], "6:00 PM")

      # 4. Undo puts Thursday back: the evening leaves the page and the layer.
      hook(lv, "calendar:undo", %{})
      assert has_element?(lv, "#calendar-toast", "Bookable times for Intro call put back.")
      await_bookable(lv, &has_window?(&1, "2026-10-15T09:00", "2026-10-15T17:00"))

      refute guest_sees?(profile, meeting_type, thursday, "6:00 PM")
      assert guest_sees?(profile, meeting_type, thursday, "4:30 PM")
    end

    test "every week widens the weekday on the booking page and Undo restores it", %{
      conn: conn,
      profile: profile,
      schedule: schedule,
      meeting_type: meeting_type
    } do
      refute guest_sees?(profile, meeting_type, ~D[2026-10-26], "7:00 AM")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      await_bookable(lv, &has_window?(&1, "2026-10-19T09:00", "2026-10-19T17:00"))

      hook(lv, "calendar:open_booking", %{
        "meeting_type" => to_string(meeting_type.id),
        "start" => "2026-10-19T07:00",
        "end" => "2026-10-19T08:00",
        "repeat" => "weekly",
        "draft" => "d1"
      })

      assert_reply(lv, %{accepted: true})

      assert has_element?(
               lv,
               "#calendar-toast",
               "Open for Intro call every Monday, 07:00 to 17:00"
             )

      # The Monday row itself is widened, so every Monday follows.
      assert %{is_available: true, start_time: ~T[07:00:00], end_time: ~T[17:00:00]} =
               WeeklySchedule.get_day_availability(schedule.id, 1)

      await_bookable(lv, &has_window?(&1, "2026-10-19T07:00", "2026-10-19T17:00"))
      assert guest_sees?(profile, meeting_type, ~D[2026-10-19], "7:00 AM")
      assert guest_sees?(profile, meeting_type, ~D[2026-10-26], "7:00 AM")

      hook(lv, "calendar:undo", %{})
      assert has_element?(lv, "#calendar-toast", "Bookable times for Intro call put back.")
      await_bookable(lv, &has_window?(&1, "2026-10-19T09:00", "2026-10-19T17:00"))

      assert %{start_time: ~T[09:00:00]} = WeeklySchedule.get_day_availability(schedule.id, 1)
      refute guest_sees?(profile, meeting_type, ~D[2026-10-26], "7:00 AM")
    end
  end

  describe "a booking request from the calendar" do
    setup %{user: user} do
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
      Application.put_env(:swoosh, :shared_test_process, self())

      on_exit(fn ->
        Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
        Application.delete_env(:swoosh, :shared_test_process)
      end)

      approval_type =
        meeting_type(user,
          name: "Consultation",
          slug: "consultation",
          requires_approval: true,
          is_active: true,
          sort_order: 1
        )

      base = %{
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_email: user.email,
        meeting_type: "Consultation",
        meeting_type_id: approval_type.id,
        duration: 30
      }

      # Thursday 10:00 to 10:30 in London, waiting for an answer.
      held =
        insert(
          :meeting,
          Map.merge(base, %{
            status: "awaiting_approval",
            attendee_name: "Anna Kowalski",
            attendee_email: "anna@example.com",
            title: "Consultation with Anna Kowalski",
            summary: "Consultation with Anna Kowalski",
            start_time: ~U[2026-10-15 09:00:00Z],
            end_time: ~U[2026-10-15 09:30:00Z],
            approval_requested_at: ~U[2026-10-14 07:00:00Z],
            approval_deadline_at: ~U[2026-10-15 07:00:00Z]
          })
        )

      # Tuesday 14:00 in London, never answered.
      expired =
        insert(
          :meeting,
          Map.merge(base, %{
            status: "expired",
            attendee_name: "Ben Okafor",
            attendee_email: "ben@example.com",
            title: "Consultation with Ben Okafor",
            summary: "Consultation with Ben Okafor",
            start_time: ~U[2026-10-13 13:00:00Z],
            end_time: ~U[2026-10-13 13:30:00Z],
            approval_requested_at: ~U[2026-10-12 09:00:00Z],
            approval_deadline_at: ~U[2026-10-13 09:00:00Z],
            approval_resolved_at: ~U[2026-10-13 09:00:00Z],
            cancelled_at: ~U[2026-10-13 09:00:00Z]
          })
        )

      %{held: held, expired: expired}
    end

    test "Accept confirms it and sends the ordinary confirmation emails", %{
      conn: conn,
      user: user,
      held: held
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # 1. The held slot is not bookable: Thursday's window breaks around it.
      payload = await_bookable(lv, &has_window?(&1, "2026-10-15T09:00", "2026-10-15T10:00"))
      assert has_window?(payload, "2026-10-15T10:30", "2026-10-15T17:00")

      # The grid draws the request guest first, flagged as a request.
      request_id = "booking-#{held.id}"

      assert %{title: "Anna Kowalski · Consultation", request: true, expired: false} =
               Enum.find(ready_events(lv), &(&1.id == request_id))

      # 2. Its preview offers Accept and Decline, and nothing a booking has.
      hook(lv, "calendar:open", %{"id" => request_id})
      assert_reply(lv, %{opened: true})
      assert has_element?(lv, "#calendar-preview-accept")
      assert has_element?(lv, "#calendar-preview-decline")
      refute has_element?(lv, "#calendar-preview-cancel")
      refute has_element?(lv, "#calendar-preview-reschedule")
      refute_enqueued(worker: EmailWorker)

      # 3. Accept. The answer runs off the LiveView, then reloads the grid.
      lv |> element("#calendar-preview-accept") |> render_click()
      render_async(lv, @push_timeout)

      assert Repo.get!(MeetingSchema, held.id).status == :confirmed

      # Accept answers with the Meetings page's flash, not a calendar toast.
      assert render(lv) =~ "Booking confirmed. The invitee has been told."

      # The grid redraws it as an ordinary booking, and the preview now offers
      # what a booking has.
      events =
        await_events(
          lv,
          &match?(%{request: false}, Enum.find(&1, fn e -> e.id == request_id end))
        )

      assert %{title: "Anna Kowalski · Consultation"} = Enum.find(events, &(&1.id == request_id))
      assert has_element?(lv, "#calendar-preview-cancel")
      refute has_element?(lv, "#calendar-preview-accept")

      # 4. The confirmation goes through the existing pipeline: one job, which
      # emails the guest and the organiser.
      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => held.id}
      )

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => held.id
               })

      assert_received {:email, one}
      assert_received {:email, other}

      recipients = Enum.map([one, other], fn email -> email.to |> hd() |> elem(1) end)
      assert Enum.sort(recipients) == Enum.sort(["anna@example.com", user.email])

      stored = Repo.get!(MeetingSchema, held.id)
      assert stored.attendee_email_sent
      assert stored.organizer_email_sent
    end

    test "an expired request opens to a quiet line, not to actions", %{
      conn: conn,
      expired: expired
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      expired_id = "booking-#{expired.id}"

      # Swept to status "expired", it is no longer awaiting an answer, but it
      # is flagged expired and holds no time.
      assert %{request: false, expired: true, free: true} =
               Enum.find(ready_events(lv), &(&1.id == expired_id))

      hook(lv, "calendar:open", %{"id" => expired_id})
      assert_reply(lv, %{opened: true})

      assert has_element?(lv, "#calendar-preview-note", "This request expired without an answer")
      refute has_element?(lv, "#calendar-preview-accept")
      refute has_element?(lv, "#calendar-preview-decline")
      assert Repo.get!(MeetingSchema, expired.id).status == :expired
    end
  end
end
