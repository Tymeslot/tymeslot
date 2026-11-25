defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedCancelledTest do
  @moduledoc """
  `checkout.session.completed` for a booking released before its payment
  was recorded: the host cancelled it while its checkout was open, and the
  attendee paid before the checkout could be closed. The money was taken for
  a booking that will not happen, so the payment is recorded and all of it
  refunded, and the booking stays cancelled.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"
  @paid_session %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"}

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  describe "handle/1 for a booking cancelled while its checkout was open" do
    test "records the payment, keeps the booking cancelled and refunds all of it" do
      meeting = insert(:meeting, status: :cancelled, cancelled_at: DateTime.utc_now(:second))

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_CANCELLED_PAID"
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, MeetingPayments.payment_topic(meeting.id))

      assert :ok =
               CheckoutSessionCompleted.handle(
                 cancelled_paid_event("evt_CANCELLED_PAID", meeting)
               )

      recorded = Repo.reload!(bp)
      assert recorded.status == :paid
      assert recorded.paid_at
      assert recorded.last_event_id == "evt_CANCELLED_PAID"

      assert [%{source: :late_payment, amount_cents: 5000, status: :pending}] = refunds(bp)
      assert [_job] = all_enqueued(worker: ExecuteRefund)

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == :cancelled

      assert_receive :expired, 1_000
      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: EmailWorker)

      # Until the refund goes through, the host sees it owed.
      assert [%{id: id}] = MeetingPayments.list_outstanding_refunds_for_host(bp.host_user_id)
      assert id == bp.id
    end

    test "a redelivery, or the reconciler's replay, refunds it once" do
      meeting = insert(:meeting, status: :cancelled, cancelled_at: DateTime.utc_now(:second))

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_CANCELLED_PAID"
        )

      event = cancelled_paid_event("evt_CANCELLED_AGAIN", meeting)

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert :ok = CheckoutSessionCompleted.handle(event)

      assert :ok =
               CheckoutSessionCompleted.handle(%{event | "id" => "reconcile:cs_CANCELLED_PAID"})

      assert [_one] = refunds(bp)
      assert [_job] = all_enqueued(worker: ExecuteRefund)
      assert Repo.reload!(bp).last_event_id == "evt_CANCELLED_AGAIN"
    end

    # A payment failed already (its checkout closed by a disconnect, say)
    # whose charge went through all the same: the cancelled booking is not
    # brought back the way an expired one can be.
    test "refunds a failed payment of a cancelled booking rather than reinstating it" do
      meeting = insert(:meeting, status: :cancelled, cancelled_at: DateTime.utc_now(:second))

      bp =
        insert_payment(
          meeting: meeting,
          status: :failed,
          stripe_checkout_session_id: "cs_CANCELLED_PAID"
        )

      assert :ok =
               CheckoutSessionCompleted.handle(
                 cancelled_paid_event("evt_CANCELLED_FAILED", meeting)
               )

      assert %{status: :paid} = Repo.reload!(bp)
      assert [%{source: :late_payment, amount_cents: 5000}] = refunds(bp)
      assert {:ok, %{status: :cancelled}} = MeetingQueries.get_meeting(meeting.id)
    end
  end

  defp cancelled_paid_event(event_id, meeting) do
    completed_event(event_id, %{
      "id" => "cs_CANCELLED_PAID",
      "client_reference_id" => meeting.id,
      "payment_intent" => "pi_CANCELLED_PAID"
    })
  end

  defp refunds(bp), do: Repo.all(from(r in RefundSchema, where: r.booking_payment_id == ^bp.id))

  defp insert_payment(attrs),
    do: insert(:booking_payment, Keyword.put_new(attrs, :stripe_account_id, @account))

  defp completed_event(event_id, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{"object" => Map.merge(@paid_session, object)}
    }
  end
end
