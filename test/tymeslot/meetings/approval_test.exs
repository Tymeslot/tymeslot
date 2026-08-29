defmodule Tymeslot.Meetings.ApprovalTest do
  @moduledoc """
  The manual-approval gate's transitions.

  The tests that matter most here are the concurrency ones: every exit from
  the gate races every other, and the guard that resolves them lives in a
  `WHERE` clause rather than in Elixir, so it has to be exercised against a
  real database rather than reasoned about.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  setup :verify_on_exit!

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp paid_held_meeting(attrs \\ %{}) do
    meeting = held_meeting(attrs)

    insert(:booking_payment, %{
      meeting_id: meeting.id,
      stripe_charge_id: "ch_TEST_#{System.unique_integer([:positive])}",
      stripe_account_id: "acct_TEST",
      amount_cents: 5000,
      refunded_amount_cents: 0,
      application_fee_cents: 0,
      status: "paid",
      paid_at: DateTime.utc_now(:second)
    })

    meeting
  end

  describe "required?/1" do
    test "follows the meeting type's flag" do
      assert Approval.required?(build(:meeting_type, requires_approval: true))
      refute Approval.required?(build(:meeting_type, requires_approval: false))
    end

    test "no meeting type means no gate" do
      refute Approval.required?(nil)
    end
  end

  describe "window_hours/1" do
    test "uses the meeting type's window when it stores one" do
      assert Approval.window_hours(build(:meeting_type, approval_window_hours: 6)) == 6
    end

    test "falls back to the application default when the meeting type stores none" do
      assert Approval.window_hours(build(:meeting_type, approval_window_hours: nil)) ==
               Constraints.default_approval_window_hours()
    end
  end

  describe "deadline_for/3" do
    test "is the request time plus the window" do
      requested_at = ~U[2026-03-01 09:00:00Z]
      start_time = ~U[2026-03-30 09:00:00Z]

      assert Approval.deadline_for(
               build(:meeting_type, approval_window_hours: 6),
               requested_at,
               start_time
             ) == ~U[2026-03-01 15:00:00Z]
    end

    test "never runs past the meeting's own start time" do
      requested_at = ~U[2026-03-01 09:00:00Z]
      start_time = ~U[2026-03-01 13:00:00Z]

      # A 24-hour window against a meeting four hours away would otherwise
      # promise the host a deadline long after the slot had come and gone.
      assert Approval.deadline_for(
               build(:meeting_type, approval_window_hours: 24),
               requested_at,
               start_time
             ) == start_time
    end
  end

  describe "approve/1" do
    test "confirms the booking and records when it was answered" do
      meeting = held_meeting()

      assert {:ok, confirmed} = Approval.approve(meeting)
      assert confirmed.status == "confirmed"

      stored = reload(meeting)
      assert stored.status == "confirmed"
      assert %DateTime{} = stored.approval_resolved_at
    end

    test "hands the confirmed booking to the ordinary notification pipeline" do
      meeting = held_meeting()

      assert {:ok, confirmed} = Approval.approve(meeting)

      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => confirmed.id}
      )
    end

    test "a second approval loses to the first rather than re-confirming" do
      meeting = held_meeting()

      assert {:ok, _confirmed} = Approval.approve(meeting)
      # The caller still holds the stale struct, exactly as a double-clicked
      # button or a second browser tab would.
      assert {:error, :not_awaiting_approval} = Approval.approve(meeting)
    end

    test "loses to an expiry that already released the slot" do
      meeting = held_meeting()

      assert {:ok, _expired} = Approval.expire(meeting)
      assert {:error, :not_awaiting_approval} = Approval.approve(meeting)

      assert reload(meeting).status == "expired"
    end

    test "refuses a request whose meeting has already started" do
      meeting =
        held_meeting(%{
          start_time: DateTime.add(DateTime.utc_now(:second), -1, :hour),
          end_time: DateTime.utc_now(:second)
        })

      assert {:error, :meeting_started} = Approval.approve(meeting)
      assert reload(meeting).status == "awaiting_approval"
    end
  end

  describe "approve/1 — flipping the tentative calendar hold" do
    test "a CalDAV meeting, addressable only by uid, still schedules the confirm" do
      meeting = held_meeting(%{provider_event_id: nil, uid: "caldav-event-42@example.com"})

      assert {:ok, confirmed} = Approval.approve(meeting)

      assert_enqueued(
        worker: Tymeslot.Workers.CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => confirmed.id}
      )
    end

    test "a meeting with no provider event id and no external uid schedules nothing" do
      meeting = held_meeting(%{provider_event_id: nil, uid: UUID.generate()})

      assert {:ok, confirmed} = Approval.approve(meeting)

      refute_enqueued(
        worker: Tymeslot.Workers.CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => confirmed.id}
      )
    end
  end

  describe "decline/2" do
    test "releases the slot and keeps the host's reason" do
      meeting = held_meeting()

      assert {:ok, declined} = Approval.decline(meeting, "  Double-booked that morning  ")
      assert declined.status == "cancelled"

      stored = reload(meeting)
      assert stored.decline_reason == "Double-booked that morning"
      assert %DateTime{} = stored.cancelled_at
      assert %DateTime{} = stored.approval_resolved_at
    end

    test "a blank reason is stored as no reason at all" do
      meeting = held_meeting()

      assert {:ok, _declined} = Approval.decline(meeting, "   ")
      assert reload(meeting).decline_reason == nil
    end

    test "cannot decline a booking that was already approved" do
      meeting = held_meeting()

      assert {:ok, _confirmed} = Approval.approve(meeting)
      assert {:error, :not_awaiting_approval} = Approval.decline(meeting, "changed my mind")

      assert reload(meeting).status == "confirmed"
    end
  end

  describe "expire/1" do
    test "releases the slot without recording a decline reason" do
      meeting = held_meeting()

      assert {:ok, expired} = Approval.expire(meeting)
      assert expired.status == "expired"

      stored = reload(meeting)
      assert stored.decline_reason == nil
      assert %DateTime{} = stored.approval_resolved_at
    end
  end

  describe "release/3 — refunding a paid request" do
    test "declining a paid request refunds the full remaining balance" do
      meeting = paid_held_meeting()
      payment = BookingPaymentQueries.by_meeting_id(meeting.id)

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == payment.stripe_charge_id
        assert params.amount == 5000
        {:ok, %{id: "re_declined"}}
      end)

      assert {:ok, _declined} = Approval.decline(meeting, "Double-booked")

      reloaded = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000

      assert_enqueued(
        worker: SendBookingPaymentRefunded,
        args: %{booking_payment_id: payment.id}
      )
    end

    test "an expiry refunds the full remaining balance too" do
      meeting = paid_held_meeting()

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.amount == 5000
        {:ok, %{id: "re_expired"}}
      end)

      assert {:ok, _expired} = Approval.expire(meeting)

      reloaded = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000
    end

    test "a request with no payment releases the slot without touching Stripe" do
      # No `expect/3` set up: Mox raises `UnexpectedCallError` on any call to
      # `StripeAdapterMock`, so a passing test here proves the refund path was
      # never entered.
      meeting = held_meeting()

      assert {:ok, _declined} = Approval.decline(meeting, "No payment on this one")

      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "a payment that was never actually paid is left alone" do
      meeting = held_meeting()

      insert(:booking_payment, %{
        meeting_id: meeting.id,
        stripe_charge_id: nil,
        amount_cents: 5000,
        refunded_amount_cents: 0,
        status: "pending",
        paid_at: nil
      })

      assert {:ok, _declined} = Approval.decline(meeting, "No charge went through")

      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "an already fully refunded payment is left alone" do
      meeting = held_meeting()

      insert(:booking_payment, %{
        meeting_id: meeting.id,
        stripe_charge_id: "ch_TEST_already_refunded",
        amount_cents: 5000,
        refunded_amount_cents: 5000,
        status: "refunded",
        paid_at: DateTime.utc_now(:second)
      })

      assert {:ok, _declined} = Approval.decline(meeting, nil)

      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "a refund failure leaves the meeting released rather than raising" do
      meeting = paid_held_meeting()

      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:error, :outside_refund_window}
      end)

      assert {:ok, expired} = Approval.expire(meeting)
      assert expired.status == "expired"
      assert reload(meeting).status == "expired"

      reloaded_payment = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert reloaded_payment.status == "paid"
      assert reloaded_payment.refunded_amount_cents == 0
    end
  end

  describe "MeetingQueries.list_expired_approval_requests/2" do
    test "selects held requests past their deadline, oldest first" do
      now = DateTime.utc_now(:second)

      long_overdue = held_meeting(%{approval_deadline_at: DateTime.add(now, -3, :hour)})
      just_overdue = held_meeting(%{approval_deadline_at: DateTime.add(now, -1, :hour)})
      still_running = held_meeting(%{approval_deadline_at: DateTime.add(now, 1, :hour)})
      already_answered = held_meeting(%{approval_deadline_at: DateTime.add(now, -5, :hour)})
      {:ok, _approved} = Approval.approve(already_answered)

      ids = now |> MeetingQueries.list_expired_approval_requests(10) |> Enum.map(& &1.id)

      assert ids == [long_overdue.id, just_overdue.id]
      refute still_running.id in ids
      refute already_answered.id in ids
    end
  end
end
