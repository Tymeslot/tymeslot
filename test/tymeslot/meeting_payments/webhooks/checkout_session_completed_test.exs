defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  describe "handle/1" do
    test "marks the booking_payment paid and the meeting confirmed" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_OK"
        )

      event =
        completed_event("evt_OK", %{
          "id" => "cs_TEST_OK",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_TEST",
          "amount_total" => bp.amount_cents,
          "currency" => bp.currency,
          "metadata" => %{"meeting_id" => meeting.id}
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "paid"
      assert reloaded.paid_at
      assert reloaded.stripe_payment_intent_id == "pi_TEST"
      assert reloaded.last_event_id == "evt_OK"

      {:ok, meeting} = MeetingQueries.get_meeting(meeting.id)
      assert meeting.status == "confirmed"
    end

    test "is idempotent — replaying the same event id is a no-op" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "paid",
          paid_at: DateTime.utc_now(:second),
          stripe_checkout_session_id: "cs_REPLAY",
          stripe_payment_intent_id: "pi_REPLAY",
          last_event_id: "evt_REPLAY"
        )

      event =
        completed_event("evt_REPLAY", %{
          "id" => "cs_REPLAY",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_REPLAY"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "paid"
      assert reloaded.last_event_id == "evt_REPLAY"
    end

    test "enqueues confirmation email jobs after a successful transition" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_EFFECTS"
        )

      event =
        completed_event("evt_EFFECTS", %{
          "id" => "cs_TEST_EFFECTS",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_EFFECTS"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert_enqueued(worker: EmailWorker)
    end

    # The public booking page reads occupancy from the organiser's connected
    # calendars, so without this write a paid booking blocks nothing and its
    # slot keeps being offered — permanently, for a type with no video room.
    test "schedules the calendar write that takes the booked slot off the page" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: nil
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_CALENDAR"
        )

      event =
        completed_event("evt_CALENDAR", %{
          "id" => "cs_TEST_CALENDAR",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_CALENDAR"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => meeting.id}
      )
    end

    test "broadcasts :paid via PubSub after a successful transition" do
      meeting = insert(:meeting, status: "awaiting_payment")

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_BCAST"
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "meeting_payment:#{meeting.id}")

      event =
        completed_event("evt_BCAST", %{
          "id" => "cs_TEST_BCAST",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_BCAST"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert_receive :paid, 1_000
    end

    test "returns :ok when no booking_payment matches (event for foreign meeting)" do
      meeting = insert(:meeting, status: "awaiting_payment")

      event =
        completed_event("evt_NOMATCH", %{
          "id" => "cs_UNKNOWN",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_UNKNOWN"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
    end

    test "leaves a non-awaiting_payment meeting unchanged (replay safety)" do
      meeting = insert(:meeting, status: "confirmed")

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "paid",
          paid_at: DateTime.utc_now(:second),
          stripe_checkout_session_id: "cs_ALREADY_CONFIRMED"
        )

      event =
        completed_event("evt_DUP", %{
          "id" => "cs_ALREADY_CONFIRMED",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_DUP"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      bp_reloaded = BookingPaymentQueries.by_checkout_session("cs_ALREADY_CONFIRMED")
      assert bp_reloaded.status == "paid"
    end

    test "recovers when expired webhook beat the completed webhook (race E3)" do
      # Regression for E3: checkout.session.expired arrived first, transitioning
      # the meeting to expired and booking_payment to failed. The subsequent
      # completed event must recover: re-confirm the meeting and mark payment paid.
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "expired",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_RACE_E3"
        )

      event =
        completed_event("evt_RACE_E3", %{
          "id" => "cs_RACE_E3",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_RACE_E3"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == "paid"
      assert reloaded_bp.paid_at
      assert reloaded_bp.stripe_payment_intent_id == "pi_RACE_E3"
      assert reloaded_bp.last_event_id == "evt_RACE_E3"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "confirmed"
    end

    test "preserves a disputed status when a dispute landed before completion" do
      # Race: the charge is disputed the instant it is captured, so the dispute
      # webhook can mark the booking_payment disputed before this completed event
      # is processed. Completion must record the payment_intent and confirm the
      # meeting without clobbering the dispute back to paid.
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "disputed",
          stripe_checkout_session_id: "cs_DISP_FIRST"
        )

      event =
        completed_event("evt_DISP_FIRST", %{
          "id" => "cs_DISP_FIRST",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_DISP_FIRST"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "disputed"
      assert reloaded.paid_at
      assert reloaded.stripe_payment_intent_id == "pi_DISP_FIRST"

      {:ok, confirmed_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed_meeting.status == "confirmed"
    end

    test "skips confirmation when payment_status is not yet paid (async payment method)" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_ASYNC"
        )

      event =
        completed_event("evt_ASYNC", %{
          "id" => "cs_TEST_ASYNC",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_ASYNC",
          "payment_status" => "unpaid"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert Repo.reload!(bp).status == "pending"
      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "awaiting_payment"
      refute_enqueued(worker: CalendarEventWorker)
    end

    test "rolls back and returns an error, instead of :ok, when the calendar enqueue fails" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_ENQUEUE_FAIL"
        )

      event =
        completed_event("evt_ENQUEUE_FAIL", %{
          "id" => "cs_TEST_ENQUEUE_FAIL",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_ENQUEUE_FAIL"
        })

      :meck.new(Oban, [:passthrough])
      :meck.expect(Oban, :insert, fn _job -> {:error, :queue_not_available} end)

      try do
        assert {:error, _reason} = CheckoutSessionCompleted.handle(event)
      after
        :meck.unload(Oban)
      end

      # The whole state transition rolled back with the failed enqueue — a
      # Stripe redelivery or the reconciler sweep must still find work to do.
      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == "pending"
      assert is_nil(reloaded_bp.last_event_id)

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "awaiting_payment"

      refute_enqueued(worker: CalendarEventWorker)
    end

    test "backfills stripe_charge_id from an atom-keyed payment intent (real adapter shape)" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_CHARGE"
        )

      # The real Stripity adapter returns an atom-keyed %Stripe.PaymentIntent{}
      # whose expanded latest_charge is a %Stripe.Charge{} struct — unlike the
      # string-keyed webhook events. The handler must read the charge id from
      # this shape too, otherwise stripe_charge_id stays blank and every
      # downstream refund/dispute lookup (keyed on it) fails.
      Mox.expect(
        Tymeslot.MeetingPayments.StripeAdapterMock,
        :retrieve_payment_intent,
        fn "pi_CHARGE", _opts -> {:ok, %{latest_charge: %{id: "ch_REAL"}}} end
      )

      event =
        completed_event("evt_CHARGE", %{
          "id" => "cs_CHARGE",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_CHARGE"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert Repo.reload!(bp).stripe_charge_id == "ch_REAL"
    end

    test "a paid booking on a meeting type requiring approval moves into the gate, not confirmed" do
      user = insert(:user)

      meeting_type =
        insert(:meeting_type, user: user, requires_approval: true, approval_window_hours: 12)

      # Stamped at booking time by `Policy.approval_attributes/2`, exactly as
      # a real paid-and-gated booking would carry them into this webhook.
      requested_at = DateTime.utc_now(:second)

      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email,
          meeting_type_id: meeting_type.id,
          approval_requested_at: requested_at,
          approval_deadline_at: DateTime.add(requested_at, 12, :hour)
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_GATED"
        )

      event =
        completed_event("evt_GATED", %{
          "id" => "cs_TEST_GATED",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_GATED"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      {:ok, gated_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert gated_meeting.status == "awaiting_approval"

      # Paid but not yet approved must not send a confirmation — only the
      # request fan-out, exactly like the free gated path.
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_confirmation_emails"})

      assert {:ok, approved} = Approval.approve(gated_meeting)
      assert approved.status == "confirmed"
    end

    test "a gated booking whose meeting type has since been deleted still fails safe into the gate" do
      user = insert(:user)
      requested_at = DateTime.utc_now(:second)

      # meeting_type_id points at nothing — as if the type were deleted or
      # deactivated between booking and this webhook — so `Approval.required?/1`
      # has no meeting type to ask. The meeting's own approval stamps, set at
      # booking time, are what this handler must fall back to.
      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email,
          meeting_type_id: nil,
          approval_requested_at: requested_at,
          approval_deadline_at: DateTime.add(requested_at, 12, :hour)
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_MISSING_TYPE"
        )

      event =
        completed_event("evt_MISSING_TYPE", %{
          "id" => "cs_TEST_MISSING_TYPE",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_MISSING_TYPE"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "awaiting_approval"
    end

    test "refreshes a stale approval deadline instead of carrying the booking-time one" do
      # A checkout session can sit open for hours (Stripe's default is 24h,
      # longer for asynchronous methods). If the clock is not re-stamped when
      # the payment finally clears, the recovered deadline can already be in
      # the past — the host's answer window would be dead on arrival.
      user = insert(:user)
      stale_requested_at = DateTime.add(DateTime.utc_now(:second), -48, :hour)

      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email,
          approval_requested_at: stale_requested_at,
          approval_deadline_at: DateTime.add(stale_requested_at, 12, :hour)
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_STALE_DEADLINE"
        )

      event =
        completed_event("evt_STALE_DEADLINE", %{
          "id" => "cs_TEST_STALE_DEADLINE",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_STALE_DEADLINE"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "awaiting_approval"
      assert DateTime.compare(reloaded.approval_requested_at, stale_requested_at) == :gt
      assert DateTime.compare(reloaded.approval_deadline_at, DateTime.utc_now()) == :gt

      job =
        Repo.get_by!(Oban.Job, worker: "Tymeslot.Meetings.Workers.ApprovalExpiryWorker")

      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "restarts the clock without shortening the window the invitee was promised" do
      # The clock restarting at the webhook is deliberate: the host is only
      # asked once the money has cleared. Its *length* must not change with it.
      # A 72-hour window stamped on the row at submission has to survive the
      # restart, rather than collapsing to the application default.
      user = insert(:user)
      requested_at = DateTime.add(DateTime.utc_now(:second), -2, :hour)
      far_start = DateTime.add(DateTime.utc_now(:second), 30, :day)

      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email,
          # Far enough out that the deadline is never capped at the start time.
          start_time: far_start,
          end_time: DateTime.add(far_start, 60, :minute),
          approval_requested_at: requested_at,
          approval_deadline_at: DateTime.add(requested_at, 72, :hour)
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_WINDOW_KEPT"
        )

      event =
        completed_event("evt_WINDOW_KEPT", %{
          "id" => "cs_TEST_WINDOW_KEPT",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_WINDOW_KEPT"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "awaiting_approval"

      window_hours =
        DateTime.diff(reloaded.approval_deadline_at, reloaded.approval_requested_at, :hour)

      assert window_hours == 72
    end

    test "the gate follows the row, not a meeting type edited while checkout was open — approval turned off" do
      # The invitee saw the approval notice and was promised a held request
      # when they paid. A host disabling approval on the meeting type while
      # the checkout session is still open must not silently confirm a
      # booking the invitee was never told would be automatic.
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, requires_approval: false)
      requested_at = DateTime.utc_now(:second)

      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email,
          meeting_type_id: meeting_type.id,
          approval_requested_at: requested_at,
          approval_deadline_at: DateTime.add(requested_at, 24, :hour)
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_TOGGLE_OFF"
        )

      event =
        completed_event("evt_TOGGLE_OFF", %{
          "id" => "cs_TEST_TOGGLE_OFF",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_TOGGLE_OFF"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "awaiting_approval"
    end

    test "the gate follows the row, not a meeting type edited while checkout was open — approval turned on" do
      # Symmetric case: the invitee was promised a confirmed booking at
      # submission time (no approval stamps on the row). A host enabling
      # approval mid-checkout must not silently gate a booking the invitee
      # was told was final, and the confirm branch must not leave stale
      # approval columns behind.
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, requires_approval: true)

      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email,
          meeting_type_id: meeting_type.id,
          approval_requested_at: nil,
          approval_deadline_at: nil
        )

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEST_TOGGLE_ON"
        )

      event =
        completed_event("evt_TOGGLE_ON", %{
          "id" => "cs_TEST_TOGGLE_ON",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_TOGGLE_ON"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "confirmed"
      assert is_nil(reloaded.approval_requested_at)
      assert is_nil(reloaded.approval_deadline_at)
    end
  end

  defp completed_event(event_id, object) do
    %{
      "id" => event_id,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{"object" => Map.put_new(object, "payment_status", "paid")}
    }
  end
end
