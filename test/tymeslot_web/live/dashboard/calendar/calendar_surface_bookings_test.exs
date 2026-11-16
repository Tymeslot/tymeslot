defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceBookingsTest do
  @moduledoc """
  Acting on bookings from the calendar's preview: Accept and Decline a
  request, Reschedule and Cancel a booking still ahead, and the quiet line
  that replaces them once the moment has passed. The actions run the
  Meetings page's own paths, so the load-bearing tests here are the ones a
  forged click cannot pass: another host's meeting, an exhausted rate limit,
  a malformed payload.

  The clock is frozen at 08:00 UTC on Wednesday 14 October 2026.
  """

  # The approval limiter is keyed per host but cleared globally in one
  # describe, and answers run in a task off the LiveView, as in
  # `BookingsApprovalTest`.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :live

  import Mox

  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  @async_timeout 1_000
  # One at a time: the module runs `async: false`.
  @hold_handler :calendar_surface_bookings_hold_answer

  setup %{conn: conn} do
    stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, _details ->
      {:ok, nil}
    end)

    stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
      {:ok, nil}
    end)

    owner(conn)
  end

  defp request(user, start_at, attrs \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user: user,
          title: "Intro call with Anna Kowalski",
          meeting_type: "Intro call",
          attendee_name: "Anna Kowalski",
          attendee_email: "anna@example.com",
          start_time: start_at,
          end_time: DateTime.add(start_at, 30, :minute),
          status: "awaiting_approval",
          approval_requested_at: ~U[2026-10-13 10:00:00Z],
          approval_deadline_at: ~U[2026-10-15 08:00:00Z]
        ],
        attrs
      )
    )
  end

  defp booking(user, start_at, attrs \\ []) do
    request(
      user,
      start_at,
      Keyword.merge(
        [status: "confirmed", approval_requested_at: nil, approval_deadline_at: nil],
        attrs
      )
    )
  end

  defp open(lv, meeting) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:open", %{"id" => "booking-#{meeting.id}"})

    assert_reply(lv, %{opened: true})
  end

  defp hook(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp payload_ids(lv) do
    hook(lv, "calendar:ready", %{})
    assert_reply(lv, %{events: events})
    Enum.map(events, & &1.id)
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  # Holds the approval of `meeting` once it has committed, so the test can
  # act while Accept is still in flight: `Approval.approve/1` logs "Booking
  # request approved" with the `meeting_id` after its transaction, and a
  # logger handler runs in the logging process, so the answer task waits
  # there holding no connection. The handler is global, so it holds only this
  # meeting's approval, and `on_exit` releases a task still held when the test
  # ends (the unlinked Agent outlives the test process to say which). Returns
  # the ref that `{:held, ref, task}` arrives with.
  defp hold_answer(meeting) do
    ref = make_ref()
    {:ok, held} = Agent.start(fn -> nil end)

    config = %{
      test: self(),
      ref: ref,
      meeting_id: meeting.id,
      held: held,
      armed: :atomics.new(1, [])
    }

    :ok = :logger.add_handler(@hold_handler, __MODULE__.HoldAnswer, %{config: config})
    Logger.put_module_level(Approval, :info)

    on_exit(fn ->
      with task when is_pid(task) <- Agent.get(held, & &1), do: send(task, {:release, ref})
      Agent.stop(held)
      :logger.remove_handler(@hold_handler)
      Logger.delete_module_level(Approval)
    end)

    ref
  end

  describe "a request" do
    test "offers Accept and Decline, nothing else", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      assert has_element?(
               lv,
               ~s|#calendar-preview-accept[phx-click="booking:accept"][phx-value-id="#{meeting.id}"]|
             )

      assert has_element?(lv, ~s|#calendar-preview-decline[phx-value-id="#{meeting.id}"]|)
      refute has_element?(lv, "#calendar-preview-cancel")
      refute has_element?(lv, "#calendar-preview-reschedule")
      refute has_element?(lv, "#calendar-preview-note")
    end

    test "Accept confirms it, shows progress meanwhile, and the preview becomes a booking's", %{
      conn: conn,
      user: user
    } do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      html = lv |> element("#calendar-preview-accept") |> render_click()
      assert html =~ "Accepting…"

      render_async(lv, @async_timeout)

      assert reload(meeting).status == :confirmed
      assert render(lv) =~ "Booking confirmed. The invitee has been told."
      assert has_element?(lv, "#calendar-preview-cancel")
      refute has_element?(lv, "#calendar-preview-accept")
    end

    test "Decline asks for an optional note, releases the slot and takes it off the grid", %{
      conn: conn,
      user: user
    } do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      lv |> element("#calendar-preview-decline") |> render_click()

      assert has_element?(lv, "#calendar-decline-request #decline-request-form")
      refute has_element?(lv, "#calendar-preview")

      lv |> form("#decline-request-form", %{"reason" => "Away that week"}) |> render_submit()
      render_async(lv, @async_timeout)

      stored = reload(meeting)
      assert stored.status == :cancelled
      assert stored.decline_reason == "Away that week"
      refute has_element?(lv, "#decline-request-form")
      refute "booking-#{meeting.id}" in payload_ids(lv)
    end

    test "Keep it open closes the decline dialog and changes nothing", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-decline") |> render_click()

      lv |> element("#calendar-decline-request button", "Keep it open") |> render_click()

      refute has_element?(lv, "#decline-request-form")
      assert reload(meeting).status == :awaiting_approval
      assert_push_event(lv, "calendar:preview-closed", %{})
    end

    test "answered elsewhere meanwhile, Accept reports it and changes nothing", %{
      conn: conn,
      user: user
    } do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      {:ok, _declined} = Approval.decline(meeting, "Already handled")

      lv |> element("#calendar-preview-accept") |> render_click()
      render_async(lv, @async_timeout)

      assert reload(meeting).status == :cancelled
      assert render(lv) =~ "That request had already been answered."
    end

    test "a forged reschedule of a request opens nothing", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      hook(lv, "booking:reschedule", %{"id" => meeting.id})

      refute has_element?(lv, "#calendar-reschedule-booking")
      assert is_nil(reload(meeting).reschedule_requested_at)
    end
  end

  describe "a booking still ahead" do
    test "offers Reschedule and Cancel, not Accept", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      assert has_element?(lv, ~s|#calendar-preview-reschedule[phx-value-id="#{meeting.id}"]|)
      assert has_element?(lv, ~s|#calendar-preview-cancel[phx-value-id="#{meeting.id}"]|)
      refute has_element?(lv, "#calendar-preview-accept")
    end

    test "Cancel asks first, then cancels it and takes it off the grid", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      lv |> element("#calendar-preview-cancel") |> render_click()

      assert has_element?(lv, "#calendar-cancel-booking #cancel-meeting-form", "Anna Kowalski")
      assert reload(meeting).status == :confirmed

      lv |> form("#cancel-meeting-form") |> render_submit()

      assert reload(meeting).status == :cancelled
      assert render(lv) =~ "Meeting cancelled successfully"
      refute has_element?(lv, "#cancel-meeting-form")
      refute "booking-#{meeting.id}" in payload_ids(lv)
    end

    test "Reschedule asks the guest for a new time and the booking leaves the grid", %{
      conn: conn,
      user: user
    } do
      meeting = booking(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      lv |> element("#calendar-preview-reschedule") |> render_click()

      assert has_element?(
               lv,
               "#calendar-reschedule-booking",
               "Send a reschedule request to Anna Kowalski?"
             )

      lv |> element("#calendar-reschedule-booking button", "Send Request") |> render_click()

      assert reload(meeting).reschedule_requested_at == ~U[2026-10-14 08:00:00Z]
      assert render(lv) =~ "Reschedule request sent to Anna Kowalski"
      refute has_element?(lv, "#calendar-reschedule-booking")
      refute "booking-#{meeting.id}" in payload_ids(lv)
    end

    test "cancelling is refused once the per-host limit is exhausted", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-cancel") |> render_click()

      for _i <- 1..20, do: assert(:ok = RateLimiter.check(:dashboard_cancel, user.id))

      lv |> form("#cancel-meeting-form") |> render_submit()

      assert render(lv) =~ "reached the limit"
      assert reload(meeting).status == :confirmed
    end

    test "rescheduling is refused once the per-host limit is exhausted", %{
      conn: conn,
      user: user
    } do
      meeting = booking(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-reschedule") |> render_click()

      for _i <- 1..20, do: assert(:ok = RateLimiter.check(:dashboard_reschedule, user.id))

      lv |> element("#calendar-reschedule-booking button", "Send Request") |> render_click()

      assert render(lv) =~ "reached the limit"
      assert is_nil(reload(meeting).reschedule_requested_at)
    end
  end

  describe "once the moment has passed" do
    test "an ended booking says so instead of offering actions", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-13 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      assert has_element?(lv, "#calendar-preview-note", "This meeting has ended")
      refute has_element?(lv, "#calendar-preview-cancel")
      refute has_element?(lv, "#calendar-preview-reschedule")
    end

    test "a request the sweep expired says it was never answered", %{conn: conn, user: user} do
      meeting =
        request(user, ~U[2026-10-16 10:00:00Z],
          status: "expired",
          approval_deadline_at: ~U[2026-10-14 07:00:00Z],
          approval_resolved_at: ~U[2026-10-14 07:00:00Z],
          cancelled_at: ~U[2026-10-14 07:00:00Z]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      assert has_element?(lv, "#calendar-preview-note", "This request expired without an answer")
      refute has_element?(lv, "#calendar-preview-accept")
    end

    test "a request the sweep expired does not claim its slot is still taken", %{
      conn: conn,
      user: user
    } do
      meeting =
        request(user, ~U[2026-10-16 10:00:00Z],
          status: "expired",
          approval_deadline_at: ~U[2026-10-14 07:00:00Z],
          approval_resolved_at: ~U[2026-10-14 07:00:00Z],
          cancelled_at: ~U[2026-10-14 07:00:00Z]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      assert has_element?(lv, "#calendar-preview", "Anna Kowalski")
      refute has_element?(lv, "#calendar-preview", "Guests can't book this time")
    end

    test "a request held past its deadline says the same before the sweep reaches it", %{
      conn: conn,
      user: user
    } do
      meeting =
        request(user, ~U[2026-10-16 12:00:00Z], approval_deadline_at: ~U[2026-10-14 07:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      assert has_element?(lv, "#calendar-preview-note", "This request expired without an answer")
      refute has_element?(lv, "#calendar-preview-accept")
    end

    test "a meeting under way offers nothing and adds no line", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-14 07:30:00Z], end_time: ~U[2026-10-14 08:30:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      assert has_element?(lv, "#calendar-preview", "Happening now")
      refute has_element?(lv, "#calendar-preview-cancel")
      refute has_element?(lv, "#calendar-preview-note")
    end
  end

  describe "an answer in flight" do
    # The held approval logs at info level; keep it off the console.
    @describetag :capture_log

    test "a second Accept answers once", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      ref = hold_answer(meeting)

      lv |> element("#calendar-preview-accept") |> render_click()
      assert_receive {:held, ^ref, task}, @async_timeout
      hook(lv, "booking:accept", %{"id" => meeting.id})
      send(task, {:release, ref})
      render_async(lv, @async_timeout)

      html = render(lv)
      assert html =~ "Booking confirmed. The invitee has been told."
      refute html =~ "That request had already been answered."
    end

    test "the same id in another case is the same request", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      ref = hold_answer(meeting)

      lv |> element("#calendar-preview-accept") |> render_click()
      assert_receive {:held, ^ref, task}, @async_timeout
      hook(lv, "booking:accept", %{"id" => String.upcase(meeting.id)})
      send(task, {:release, ref})
      render_async(lv, @async_timeout)

      html = render(lv)
      assert html =~ "Booking confirmed. The invitee has been told."
      refute html =~ "That request had already been answered."
    end

    test "a forged Decline does nothing while Accept runs", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      ref = hold_answer(meeting)

      lv |> element("#calendar-preview-accept") |> render_click()
      assert_receive {:held, ^ref, task}, @async_timeout
      hook(lv, "booking:decline", %{"id" => meeting.id})
      refute has_element?(lv, "#calendar-decline-request")
      send(task, {:release, ref})
      render_async(lv, @async_timeout)

      html = render(lv)
      assert html =~ "Booking confirmed. The invitee has been told."
      refute html =~ "That request had already been answered."
    end

    test "confirming a Decline while Accept runs does not drop the Accept", %{
      conn: conn,
      user: user
    } do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-decline") |> render_click()
      ref = hold_answer(meeting)

      hook(lv, "booking:accept", %{"id" => meeting.id})
      assert_receive {:held, ^ref, task}, @async_timeout
      lv |> form("#decline-request-form", %{"reason" => "Away"}) |> render_submit()
      send(task, {:release, ref})
      render_async(lv, @async_timeout)

      assert reload(meeting).status == :confirmed
      html = render(lv)
      assert html =~ "Booking confirmed. The invitee has been told."
      refute html =~ "That request had already been answered."
    end

    test "another request's dialog is not shown as declining while Accept runs", %{
      conn: conn,
      user: user
    } do
      first = request(user, ~U[2026-10-15 10:00:00Z])
      second = request(user, ~U[2026-10-15 13:00:00Z], attendee_name: "Ben Ode")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      ref = hold_answer(first)

      hook(lv, "booking:accept", %{"id" => first.id})
      assert_receive {:held, ^ref, task}, @async_timeout
      hook(lv, "booking:decline", %{"id" => second.id})

      assert has_element?(lv, "#calendar-decline-request #decline-request-form", "Ben Ode")
      refute render(lv) =~ "Declining..."

      send(task, {:release, ref})
      render_async(lv, @async_timeout)
    end

    test "one request's answer finishing leaves another's still in flight", %{
      conn: conn,
      user: user
    } do
      first = request(user, ~U[2026-10-15 10:00:00Z])
      second = request(user, ~U[2026-10-15 13:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      ref = hold_answer(first)

      hook(lv, "booking:accept", %{"id" => first.id})
      assert_receive {:held, ^ref, task}, @async_timeout
      hook(lv, "booking:accept", %{"id" => second.id})
      eventually(fn -> render(lv) =~ "Booking confirmed. The invitee has been told." end)

      # The first answer is still running, so its Accept stays refused.
      hook(lv, "booking:accept", %{"id" => first.id})
      send(task, {:release, ref})
      render_async(lv, @async_timeout)

      assert reload(first).status == :confirmed
      assert reload(second).status == :confirmed
      refute render(lv) =~ "That request had already been answered."
    end
  end

  describe "client input is never trusted" do
    @describetag :cross_tenant

    test "another host's request cannot be accepted", %{conn: conn} do
      stranger = insert(:user)
      theirs = request(stranger, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      hook(lv, "booking:accept", %{"id" => theirs.id})
      render_async(lv, @async_timeout)

      assert reload(theirs).status == :awaiting_approval
      assert render(lv) =~ "That request could not be found."
    end

    test "another host's booking opens no dialog", %{conn: conn} do
      stranger = insert(:user)
      theirs = booking(stranger, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      hook(lv, "booking:cancel", %{"id" => theirs.id})
      hook(lv, "booking:reschedule", %{"id" => theirs.id})
      hook(lv, "booking:decline", %{"id" => theirs.id})

      refute has_element?(lv, "#calendar-cancel-booking")
      refute has_element?(lv, "#calendar-reschedule-booking")
      refute has_element?(lv, "#calendar-decline-request")
    end

    test "a forged cancel of the host's own ended meeting is refused", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-13 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      hook(lv, "booking:cancel", %{"id" => meeting.id})

      assert render(lv) =~ "Cannot cancel a meeting that has already occurred"
      refute has_element?(lv, "#calendar-cancel-booking")
      assert reload(meeting).status == :confirmed
    end

    test "a confirm with no dialog open does nothing", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      hook(lv, "booking:confirm_cancel", %{})
      hook(lv, "booking:confirm_reschedule", %{})
      hook(lv, "booking:confirm_decline", %{"reason" => "x"})

      assert reload(meeting).status == :confirmed
      assert is_nil(reload(meeting).reschedule_requested_at)
    end

    test "malformed payloads change nothing and crash nothing", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      hook(lv, "booking:accept", %{"id" => 5})
      hook(lv, "booking:accept", %{})
      hook(lv, "booking:accept", %{"id" => "not-a-uuid"})
      hook(lv, "booking:cancel", %{"id" => ["x"]})
      hook(lv, "booking:close", %{"modal" => "nope"})
      hook(lv, "booking:explode", %{})
      render_async(lv, @async_timeout)

      assert Process.alive?(lv.pid)
      assert reload(meeting).status == :awaiting_approval
    end
  end

  describe "rate limiting" do
    setup do
      RateLimiter.clear_all()
      :ok
    end

    test "accepting is refused once the per-host limit is exhausted, shared with Meetings", %{
      conn: conn,
      user: user
    } do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)

      for _i <- 1..20,
          do: assert(:ok = RateLimiter.check(:dashboard_meeting_approval, user.id))

      lv |> element("#calendar-preview-accept") |> render_click()

      assert render(lv) =~ "reached the limit"
      assert reload(meeting).status == :awaiting_approval
    end

    test "declining is refused once the per-host limit is exhausted", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-decline") |> render_click()

      for _i <- 1..20,
          do: assert(:ok = RateLimiter.check(:dashboard_meeting_approval, user.id))

      lv |> form("#decline-request-form", %{"reason" => "Away"}) |> render_submit()
      render_async(lv, @async_timeout)

      assert render(lv) =~ "reached the limit"
      assert reload(meeting).status == :awaiting_approval
    end
  end

  defmodule HoldAnswer do
    @moduledoc false

    @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
    def log(%{msg: {:string, message}, meta: %{meeting_id: meeting_id}}, %{
          config: %{meeting_id: meeting_id, test: test, ref: ref, held: held, armed: armed}
        }) do
      if IO.chardata_to_string(message) == "Booking request approved" and
           :atomics.compare_exchange(armed, 1, 0, 1) == :ok do
        task = self()
        Agent.update(held, fn _nobody -> task end)
        send(test, {:held, ref, task})

        receive do
          {:release, ^ref} -> :ok
        end
      end

      :ok
    end

    def log(_event, _config), do: :ok
  end
end
