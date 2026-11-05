defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceBookingDialogsTest do
  @moduledoc """
  The journeys through the calendar's booking dialogs, beyond the
  actions themselves (`CalendarSurfaceBookingsTest`): opening Cancel,
  Decline or Reschedule tells nobody, confirming queues the guest's email,
  a dialog confirmed after another tab answered first says so, a refused
  reschedule keeps its dialog open, and a refund chosen for a paid booking
  reaches the cancellation. Last, the calendar copy a drawn booking hides
  cannot be deleted, moved or edited by its id.

  The clock is frozen at 08:00 UTC on Wednesday 14 October 2026.
  """

  # Answers run in a task off the LiveView, and the Stripe mock is reached
  # from the LiveView's process, as in `CalendarSurfaceBookingsTest`.
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :live

  import Mox

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventDeleteWorker
  alias Tymeslot.Workers.EmailWorker

  @async_timeout 1_000

  setup :verify_on_exit!

  setup %{conn: conn}, do: owner(conn)

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

  defp hook(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp open(lv, meeting) do
    hook(lv, "calendar:open", %{"id" => "booking-#{meeting.id}"})
    assert_reply(lv, %{opened: true})
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp emails, do: all_enqueued(worker: EmailWorker)

  describe "opening a dialog" do
    test "Cancel, Decline and Reschedule send nothing until confirmed", %{
      conn: conn,
      user: user
    } do
      held = request(user, ~U[2026-10-15 10:00:00Z])
      confirmed = booking(user, ~U[2026-10-15 13:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open(lv, confirmed)
      lv |> element("#calendar-preview-cancel") |> render_click()
      assert has_element?(lv, "#cancel-meeting-form")
      lv |> element("#calendar-cancel-booking button", "Keep Meeting") |> render_click()

      open(lv, confirmed)
      lv |> element("#calendar-preview-reschedule") |> render_click()
      assert has_element?(lv, "#calendar-reschedule-booking")
      hook(lv, "booking:close", %{"modal" => "reschedule"})

      open(lv, held)
      lv |> element("#calendar-preview-decline") |> render_click()
      assert has_element?(lv, "#decline-request-form")

      assert emails() == []
      assert reload(confirmed).status == :confirmed
      assert is_nil(reload(confirmed).reschedule_requested_at)
      assert reload(held).status == :awaiting_approval
    end
  end

  describe "confirming a dialog" do
    test "Cancel queues the guest's cancellation email", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-15 13:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-cancel") |> render_click()

      lv |> form("#cancel-meeting-form") |> render_submit()

      assert reload(meeting).status == :cancelled

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}
      )
    end

    test "Decline queues the guest's email saying so", %{conn: conn, user: user} do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-decline") |> render_click()

      lv |> form("#decline-request-form", %{"reason" => "Away"}) |> render_submit()
      render_async(lv, @async_timeout)

      assert reload(meeting).status == :cancelled

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_outcome", "meeting_id" => meeting.id}
      )
    end

    test "Reschedule queues the guest's request for a new time", %{conn: conn, user: user} do
      meeting = booking(user, ~U[2026-10-15 13:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-reschedule") |> render_click()

      lv |> element("#calendar-reschedule-booking button", "Send Request") |> render_click()

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
      )
    end
  end

  describe "after another tab answered first" do
    test "Cancel says the booking was already cancelled, and emails nobody again", %{
      conn: conn,
      user: user
    } do
      meeting = booking(user, ~U[2026-10-15 13:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-cancel") |> render_click()

      meeting
      |> Changeset.change(status: :cancelled, cancelled_at: ~U[2026-10-14 07:59:00Z])
      |> Repo.update!()

      lv |> form("#cancel-meeting-form") |> render_submit()

      assert render(lv) =~ "This booking was already cancelled."
      refute has_element?(lv, "#cancel-meeting-form")
      assert emails() == []
    end

    test "Decline of a request already answered says so and changes nothing", %{
      conn: conn,
      user: user
    } do
      meeting = request(user, ~U[2026-10-15 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, meeting)
      lv |> element("#calendar-preview-decline") |> render_click()

      {:ok, _approved} = Approval.approve(meeting)

      lv |> form("#decline-request-form", %{"reason" => "Away"}) |> render_submit()
      render_async(lv, @async_timeout)

      assert render(lv) =~ "That request had already been answered."
      assert reload(meeting).status == :confirmed

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_outcome", "meeting_id" => meeting.id}
      )
    end
  end

  test "a refused reschedule keeps its dialog open with the reason", %{conn: conn, user: user} do
    meeting = booking(user, ~U[2026-10-15 13:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, meeting)
    lv |> element("#calendar-preview-reschedule") |> render_click()

    meeting
    |> Changeset.change(status: :cancelled, cancelled_at: ~U[2026-10-14 07:59:00Z])
    |> Repo.update!()

    lv |> element("#calendar-reschedule-booking button", "Send Request") |> render_click()

    assert has_element?(lv, "#calendar-reschedule-booking")
    refute render(lv) =~ "Reschedule request sent"
    assert is_nil(reload(meeting).reschedule_requested_at)
  end

  test "a refund chosen for a paid booking reaches the cancellation", %{conn: conn, user: user} do
    meeting = booking(user, ~U[2026-10-15 13:00:00Z])

    payment =
      insert(:booking_payment,
        meeting_id: meeting.id,
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_PAID",
        stripe_charge_id: "ch_PAID_#{System.unique_integer([:positive])}",
        amount_cents: 5000,
        application_fee_cents: 25,
        currency: "eur",
        status: "paid",
        paid_at: ~U[2026-10-12 09:00:00Z],
        refunded_amount_cents: 0
      )

    expect(StripeAdapterMock, :create_refund, fn params, _opts ->
      assert params.amount == 5000
      {:ok, %{id: "re_calendar_full"}}
    end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, meeting)
    lv |> element("#calendar-preview-cancel") |> render_click()

    lv
    |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
    |> render_submit()

    assert render(lv) =~ "Meeting cancelled and refund issued"
    assert reload(meeting).status == :cancelled

    assert %{status: :refunded, refunded_amount_cents: 5000} =
             BookingPaymentQueries.get(payment.id)
  end

  describe "the calendar copy a drawn booking hides" do
    setup %{user: user, integration: integration} do
      copy = event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30)

      meeting =
        booking(user, ~U[2026-10-15 13:00:00Z],
          calendar_integration_id: integration.id,
          calendar_uid: copy.uid
        )

      %{copy: copy, meeting: meeting}
    end

    test "is not on the grid, while its booking is", %{conn: conn, copy: copy, meeting: meeting} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      hook(lv, "calendar:ready", %{})
      assert_reply(lv, %{events: events})

      ids = Enum.map(events, & &1.id)
      assert "booking-#{meeting.id}" in ids
      refute "event-#{copy.id}" in ids
    end

    test "cannot be deleted, moved or edited by its id", %{
      conn: conn,
      copy: copy,
      meeting: meeting
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      id = "event-#{copy.id}"

      hook(lv, "calendar:delete", %{"id" => id})

      hook(lv, "calendar:move", %{
        "id" => id,
        "start" => "2026-10-15T16:00",
        "end" => "2026-10-15T16:30"
      })

      hook(lv, "calendar:edit", %{"id" => id})

      refute has_element?(lv, "#calendar-delete-confirm")
      refute has_element?(lv, "#calendar-undo")
      refute has_element?(lv, "#calendar-panel")
      refute_enqueued(worker: CalendarEventDeleteWorker)

      stored = Repo.reload!(copy)
      assert DateTime.compare(stored.start_at, copy.start_at) == :eq
      assert reload(meeting).status == :confirmed
      assert DateTime.compare(reload(meeting).start_time, meeting.start_time) == :eq
    end
  end
end
