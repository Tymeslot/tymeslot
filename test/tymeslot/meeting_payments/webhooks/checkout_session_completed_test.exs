defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
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
  end

  defp completed_event(event_id, object) do
    %{
      "id" => event_id,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{"object" => object}
    }
  end
end
