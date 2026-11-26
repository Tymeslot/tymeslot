defmodule Tymeslot.MeetingPayments.Webhooks.RefundUpdatedTest do
  # async: false: admin alerts are captured through application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :integration
  @moduletag :capture_log

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.MeetingPayments.Webhooks.RefundUpdated
  alias Tymeslot.MeetingPayments.Webhooks.WebhookRegistry
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.StripeWebhookFixtures
  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias Tymeslot.Workers.SendRefundFailed

  @account "acct_TEST_HOST"

  setup :capture_admin_alerts

  defp refunded_payment(attrs \\ []) do
    insert(
      :paid_booking_payment,
      [
        stripe_account_id: @account,
        stripe_charge_id: "ch_UPDATED",
        amount_cents: 5_000,
        refunded_amount_cents: 5_000,
        status: :refunded
      ] ++ attrs
    )
  end

  defp succeeded_refund(payment) do
    insert(:booking_payment_refund,
      booking_payment: payment,
      amount_cents: 5_000,
      status: :succeeded,
      stripe_refund_id: "re_UPDATED",
      settled_at: DateTime.utc_now(:second)
    )
  end

  # The refund as Stripe sends it in the event: its charge an id. The
  # metadata replaces the fixture's rather than merging into it, so `%{}` is
  # a refund made in the dashboard, naming no row.
  defp stripe_refund(refund, status, metadata \\ nil) do
    "refund"
    |> StripeFixtures.object(%{
      "id" => "re_UPDATED",
      "amount" => refund.amount_cents,
      "charge" => "ch_UPDATED",
      "status" => status
    })
    |> Map.put("metadata", metadata || %{"tymeslot_refund_id" => refund.id})
  end

  defp event_for(stripe_refund) do
    "refund.updated"
    |> StripeWebhookFixtures.connect_event(stripe_refund, @account)
    |> Jason.decode!()
  end

  # The refund as the handler reads it again: its charge expanded, showing
  # Stripe's refunded total now.
  defp current(stripe_refund, charge_refunded) do
    Map.put(stripe_refund, "charge", %{
      "id" => "ch_UPDATED",
      "object" => "charge",
      "amount_refunded" => charge_refunded
    })
  end

  defp deliver(stripe_refund, charge_refunded) do
    StripeStub.expect(:retrieve_refund, current(stripe_refund, charge_refunded))
    RefundUpdated.handle(event_for(stripe_refund))
  end

  @refused {403, %{"error" => %{"type" => "invalid_request_error", "code" => "account_invalid"}}}

  test "is the handler for refund.updated and charge.refund.updated" do
    assert WebhookRegistry.handler_for("refund.updated") == RefundUpdated
    assert WebhookRegistry.handler_for("charge.refund.updated") == RefundUpdated
  end

  test "refund.updated to failed takes a succeeded refund off the total" do
    payment = refunded_payment()
    refund = succeeded_refund(payment)

    assert :ok = deliver(stripe_refund(refund, "failed"), 0)

    assert [%{path: "/v1/refunds/re_UPDATED", query: query, headers: headers}] =
             StripeStub.requests(:retrieve_refund)

    assert query["expand"] == ["charge"]
    assert headers["stripe-account"] == @account

    assert %{status: :failed, failure_code: "refund_failed"} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)

    refund_id = refund.id

    assert_received {:send_alert, :refund_failed,
                     %{refund_id: ^refund_id, failure_code: "refund_failed"}}

    assert_enqueued(worker: SendRefundFailed, args: %{refund_id: refund_id})
  end

  test "refund.updated for a disputed payment keeps the disputed status" do
    payment =
      refunded_payment(
        status: :disputed,
        refunded_amount_cents: 5_000,
        disputed_lost_cents: 0
      )

    refund = succeeded_refund(payment)

    assert :ok = deliver(stripe_refund(refund, "canceled"), 0)

    assert %{status: :failed, failure_code: "refund_canceled"} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 0, status: :disputed} = Repo.reload!(payment)
  end

  test "refund.updated replayed is a no-op" do
    payment = refunded_payment()
    refund = succeeded_refund(payment)
    failed = stripe_refund(refund, "failed")
    StripeStub.stub(:retrieve_refund, current(failed, 0))
    event = event_for(failed)

    assert :ok = RefundUpdated.handle(event)
    assert_received {:send_alert, :refund_failed, _alert}

    assert :ok = RefundUpdated.handle(event)

    assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
    refute_received {:send_alert, :refund_failed, _alert}
    assert [_one] = all_enqueued(worker: SendRefundFailed)
  end

  # A charge Tymeslot never made: its payment intent names no booking.
  test "refund.updated for an unknown charge is acknowledged" do
    StripeStub.expect(
      :retrieve_payment_intent,
      StripeFixtures.object("payment_intent_with_latest_charge", %{"metadata" => %{}})
    )

    refund = build(:booking_payment_refund, id: UUID.generate())

    assert :ok = RefundUpdated.handle(event_for(stripe_refund(refund, "failed")))

    assert StripeStub.requests(:retrieve_refund) == []
    assert Repo.aggregate(RefundSchema, :count) == 0
    refute_received {:send_alert, _type, _alert}
  end

  test "refund.updated to failed settles a pending refund failed and tells the host" do
    payment = refunded_payment(refunded_amount_cents: 0, status: :paid)
    refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

    assert :ok = deliver(stripe_refund(refund, "failed"), 0)

    assert %{status: :failed, failure_code: "refund_failed", stripe_refund_id: "re_UPDATED"} =
             RefundQueries.get(refund.id)

    assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
    assert_enqueued(worker: SendRefundFailed, args: %{refund_id: refund.id})
    refute_enqueued(worker: SendBookingPaymentRefunded)
  end

  test "refund.updated to succeeded settles a pending refund and emails the attendee" do
    payment = refunded_payment(refunded_amount_cents: 0, status: :paid)
    refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

    assert :ok = deliver(stripe_refund(refund, "succeeded"), 2_000)

    assert %{status: :succeeded, stripe_refund_id: "re_UPDATED"} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 2_000, status: :partially_refunded} = Repo.reload!(payment)
    assert_enqueued(worker: SendBookingPaymentRefunded, args: %{booking_payment_id: payment.id})
  end

  # As after charge.refunded recorded the charge's total but could not list
  # its refunds, leaving the row pending.
  test "a refund already in the total is settled without being counted again" do
    payment = refunded_payment(refunded_amount_cents: 2_000, status: :partially_refunded)
    refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

    assert :ok = deliver(stripe_refund(refund, "succeeded"), 2_000)

    assert %{status: :succeeded} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 2_000, status: :partially_refunded} = Repo.reload!(payment)
  end

  test "refund.updated for a failed dashboard refund records nothing" do
    payment = refunded_payment()
    refund = build(:booking_payment_refund, id: nil, amount_cents: 1_000)

    assert :ok = deliver(stripe_refund(refund, "failed", %{}), 5_000)

    assert RefundQueries.list_for_payment(payment.id) == []
    assert %{refunded_amount_cents: 5_000} = Repo.reload!(payment)
  end

  # charge.refunded for the dashboard refund is still on its way.
  test "a dashboard refund recorded from refund.updated and then failed leaves the earlier total" do
    payment = refunded_payment(refunded_amount_cents: 1_000, status: :partially_refunded)
    dashboard = build(:booking_payment_refund, id: nil, amount_cents: 1_500)

    assert :ok = deliver(stripe_refund(dashboard, "pending", %{}), 2_500)

    assert [%{source: :external, status: :succeeded, amount_cents: 1_500}] =
             RefundQueries.list_for_payment(payment.id)

    assert %{refunded_amount_cents: 2_500} = Repo.reload!(payment)
    refute_enqueued(worker: SendBookingPaymentRefunded)

    assert :ok = deliver(stripe_refund(dashboard, "failed", %{}), 1_000)

    assert [%{source: :external, status: :failed}] = RefundQueries.list_for_payment(payment.id)
    assert %{refunded_amount_cents: 1_000, status: :partially_refunded} = Repo.reload!(payment)
  end

  # The attempt's answer was sent before the refund failed at Stripe, and
  # arrives after refund.updated recorded the failure.
  test "an attempt answered before Stripe failed the refund does not undo the failure" do
    payment = refunded_payment(refunded_amount_cents: 0, status: :paid)
    refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

    StripeStub.expect(:create_refund, fn request ->
      assert :ok = deliver(stripe_refund(refund, "failed"), 0)

      request
      |> StripeStubResponses.refund("re_UPDATED")
      |> Map.put("status", "pending")
    end)

    assert {:error, :refund_failed} = Refunds.execute(refund, [])

    assert %{status: :failed, failure_code: "refund_failed"} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
    refute_enqueued(worker: SendBookingPaymentRefunded)
    refute_received {:send_alert, :refund_failure_reversed, _alert}
  end

  test "a second Stripe refund made for one refund is reported, the refund left as it is" do
    payment = refunded_payment(refunded_amount_cents: 5_000, stripe_refunded_cents: 5_000)
    refund = succeeded_refund(payment)

    second =
      StripeFixtures.object("refund", %{
        "id" => "re_SECOND",
        "amount" => 5_000,
        "charge" => "ch_UPDATED",
        "status" => "succeeded",
        "metadata" => %{"tymeslot_refund_id" => refund.id}
      })

    assert :ok = deliver(second, 5_000)

    refund_id = refund.id

    assert_received {:send_alert, :refund_duplicated,
                     %{
                       refund_id: ^refund_id,
                       stripe_refund_id: "re_UPDATED",
                       duplicate_stripe_refund_id: "re_SECOND",
                       duplicate_amount_cents: 5_000
                     }}

    assert [%{id: ^refund_id, status: :succeeded, stripe_refund_id: "re_UPDATED"}] =
             RefundQueries.list_for_payment(payment.id)

    assert %{refunded_amount_cents: 5_000} = Repo.reload!(payment)
    refute_enqueued(worker: SendBookingPaymentRefunded)
  end

  # Refund B's answer shows the charge's total from before refund A
  # failed, and arrives after refund.updated took A off.
  test "a refund whose answer predates another's failure does not count that one again" do
    payment =
      refunded_payment(
        refunded_amount_cents: 2_000,
        stripe_refunded_cents: 2_000,
        status: :partially_refunded
      )

    refund_a =
      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 2_000,
        status: :succeeded,
        stripe_refund_id: "re_UPDATED",
        settled_at: DateTime.utc_now(:second)
      )

    refund_b = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 1_000)

    StripeStub.expect(:create_refund, fn request ->
      assert :ok = deliver(stripe_refund(refund_a, "failed"), 1_000)
      StripeStubResponses.refund(request, "re_B", 2_000)
    end)

    assert {:ok, %{status: :succeeded}} = Refunds.execute(refund_b, [])

    assert %{status: :failed} = RefundQueries.get(refund_a.id)

    assert %{stripe_refunded_cents: 1_000, refunded_amount_cents: 1_000} =
             Repo.reload!(payment)
  end

  # charge.refunded lists the charge's refunds while Stripe still counts
  # refund A, and refund.updated takes A off before the total is written.
  test "a charge total listed before another refund failed does not count that one again" do
    payment =
      refunded_payment(
        refunded_amount_cents: 3_000,
        stripe_refunded_cents: 3_000,
        status: :partially_refunded
      )

    refund_a =
      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 2_000,
        status: :succeeded,
        stripe_refund_id: "re_UPDATED",
        settled_at: DateTime.utc_now(:second)
      )

    refund_b =
      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 1_000,
        status: :succeeded,
        stripe_refund_id: "re_B",
        settled_at: DateTime.utc_now(:second)
      )

    listed = fn refund, stripe_id ->
      refund
      |> stripe_refund("succeeded")
      |> Map.put("id", stripe_id)
      |> current(3_000)
    end

    StripeStub.expect(:list_refunds, fn _request ->
      assert :ok = deliver(stripe_refund(refund_a, "failed"), 1_000)
      StripeFixtures.list([listed.(refund_a, "re_UPDATED"), listed.(refund_b, "re_B")])
    end)

    charge =
      StripeFixtures.object("charge", %{
        "id" => "ch_UPDATED",
        "amount" => 5_000,
        "amount_refunded" => 3_000
      })

    assert :ok =
             "charge.refunded"
             |> StripeWebhookFixtures.connect_event(charge, @account)
             |> Jason.decode!()
             |> ChargeRefunded.handle()

    assert %{status: :failed} = RefundQueries.get(refund_a.id)

    assert %{stripe_refunded_cents: 1_000, refunded_amount_cents: 1_000} =
             Repo.reload!(payment)
  end

  describe "a refund Stripe will not read again" do
    test "a transient read retries the event" do
      payment = refunded_payment()
      refund = succeeded_refund(payment)
      StripeStub.expect(:retrieve_refund, 3, {:transport_error, :timeout})

      assert {:error, :retry_later, _reason} =
               RefundUpdated.handle(event_for(stripe_refund(refund, "failed")))

      assert %{status: :succeeded} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 5_000} = Repo.reload!(payment)
    end

    test "is settled from the event when it ended" do
      payment = refunded_payment()
      refund = succeeded_refund(payment)
      StripeStub.expect(:retrieve_refund, @refused)

      assert :ok = RefundUpdated.handle(event_for(stripe_refund(refund, "failed")))

      assert %{status: :failed} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
    end

    test "is left to its attempts when committed" do
      payment = refunded_payment(refunded_amount_cents: 2_000, status: :partially_refunded)
      refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)
      StripeStub.expect(:retrieve_refund, @refused)

      assert :ok = RefundUpdated.handle(event_for(stripe_refund(refund, "succeeded")))

      assert %{status: :pending} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end
  end
end
