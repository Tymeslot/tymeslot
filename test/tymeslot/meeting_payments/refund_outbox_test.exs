defmodule Tymeslot.MeetingPayments.RefundOutboxTest do
  @moduledoc """
  A refund is recorded before Stripe is asked for it, and asked for outside
  any transaction, so a slow or ambiguous Stripe call can neither hold the
  payment's lock nor be lost, and a retry never makes a second refund.
  """

  # async: false: admin alerts are captured through application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration
  @moduletag :capture_log

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  setup :capture_admin_alerts

  setup do
    host = insert(:user)

    payment =
      insert(:paid_booking_payment, host_user_id: host.id, stripe_account_id: "acct_OUTBOX")

    %{host: host, payment: payment}
  end

  describe "request_refund/4" do
    test "request_refund records a pending refund and its safety job without calling Stripe",
         %{payment: payment} do
      StripeStub.stub(:create_refund, StripeStubResponses.refund("re_UNASKED"))

      assert {:ok, refund} = Refunds.request_refund(payment, 2_000, :host, [])

      assert StripeStub.requests() == []

      assert %{status: :pending, amount_cents: 2_000, source: :host} =
               RefundQueries.get(refund.id)

      assert_enqueued(worker: ExecuteRefund, args: %{"refund_id" => refund.id})
    end

    test "a pending refund counts against the remainder", %{payment: payment} do
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 3_000)

      assert {:error, :refund_in_progress} = Refunds.request_refund(payment, 3_000, :host, [])
      assert {:ok, %{amount_cents: 2_000}} = Refunds.request_refund(payment, 2_000, :host, [])
    end

    test "the remaining balance of a payment loaded without its pending refunds reads them",
         %{payment: payment} do
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 3_000)

      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 500,
        status: :failed
      )

      loaded = Repo.reload!(payment)
      assert loaded.pending_refund_cents == nil
      assert Refunds.refundable_remaining_cents(loaded) == 2_000
    end

    test "an amount over the balance with nothing pending is invalid", %{payment: payment} do
      assert {:error, :invalid_amount} = Refunds.request_refund(payment, 5_001, :host, [])
      assert {:error, :invalid_amount} = Refunds.request_refund(payment, 0, :host, [])
      assert RefundQueries.list_for_payment(payment.id) == []
    end

    test "a payment refunded in full is refused", %{payment: payment} do
      payment =
        Repo.update!(Changeset.change(payment, status: :refunded, refunded_amount_cents: 5_000))

      assert {:error, :already_refunded} = Refunds.request_refund(payment, 1_000, :host, [])
    end

    test "a payment under dispute is refused", %{payment: payment} do
      payment = Repo.update!(Changeset.change(payment, status: :disputed))

      assert {:error, :under_dispute} = Refunds.request_refund(payment, 1_000, :host, [])
    end

    test "another host's payment is not found", %{payment: payment} do
      other = insert(:user)

      assert {:error, :not_found} =
               Refunds.request_refund(payment, 1_000, :host, host_user_id: other.id)

      assert RefundQueries.list_for_payment(payment.id) == []
    end

    test "records who asked, the reason and the scheduling the caller chose",
         %{host: host, payment: payment} do
      assert {:ok, refund} =
               Refunds.request_refund(payment, 1_000, :host,
                 host_user_id: host.id,
                 reason: "requested_by_customer",
                 enqueue_now: true
               )

      assert %{requested_by_user_id: host_id, reason: "requested_by_customer"} = refund
      assert host_id == host.id

      assert [job] = all_enqueued(worker: ExecuteRefund)
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
    end
  end

  describe "issue_refund/4 beside a pending refund" do
    test "refunds only what the pending refund leaves", %{payment: payment} do
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 3_000)
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LEGACY_PATH"))

      assert {:error, :refund_in_progress} = Refunds.issue_refund(payment, 3_000, "legacy:3000")
      assert StripeStub.requests(:create_refund) == []

      assert {:ok, %{refunded_amount_cents: 2_000}} =
               Refunds.issue_refund(payment, 2_000, "legacy:2000")
    end
  end

  describe "refund_now/4" do
    test "refund_now refunds and records Stripe's total", %{payment: payment} do
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_NOW"))

      assert {:ok, %{status: :succeeded} = refund} =
               Refunds.refund_now(payment, payment.amount_cents, :host, [])

      assert refund.stripe_refund_id == "re_NOW"

      reloaded = Repo.reload!(payment)
      assert reloaded.refunded_amount_cents == 5_000
      assert reloaded.status == :refunded

      assert_enqueued(
        worker: SendBookingPaymentRefunded,
        args: %{"booking_payment_id" => payment.id}
      )

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_refund)
      assert form["metadata"]["tymeslot_refund_id"] == refund.id
      assert form["metadata"]["booking_payment_id"] == payment.id
      assert form["amount"] == "5000"
      assert headers["idempotency-key"] == "tymeslot:refund:#{refund.id}:1"
      assert headers["stripe-account"] == "acct_OUTBOX"
    end

    test "a partial refund leaves the payment partially refunded", %{payment: payment} do
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_PART"))

      assert {:ok, %{status: :succeeded}} = Refunds.refund_now(payment, 1_500, :host, [])

      assert %{refunded_amount_cents: 1_500, status: :partially_refunded} =
               Repo.reload!(payment)
    end

    test "no transaction is open while Stripe is called", %{payment: payment} do
      test_pid = self()

      StripeStub.expect(:create_refund, fn request ->
        send(test_pid, {:in_tx, Repo.in_transaction?()})
        StripeStubResponses.refund(request, "re_NO_TX")
      end)

      assert {:ok, _refund} = Refunds.refund_now(payment, 1_000, :host, [])
      assert_received {:in_tx, false}
    end

    test "an ambiguous timeout is resolved by adopting the refund Stripe made",
         %{payment: payment} do
      StripeStub.stub(:create_refund, {:transport_error, :timeout})

      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])
      first_attempt_creates = StripeStub.requests(:create_refund)
      assert first_attempt_creates != []

      made =
        StripeFixtures.object("refund_with_charge", %{
          "id" => "re_MADE",
          "amount" => 2_000,
          "metadata" => %{"tymeslot_refund_id" => refund.id},
          "charge" => %{"amount_refunded" => 2_000}
        })

      other = StripeFixtures.object("refund", %{"id" => "re_OTHER", "metadata" => %{}})
      StripeStub.expect(:list_refunds, StripeFixtures.list([other, made]))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert StripeStub.requests(:create_refund) == first_attempt_creates
      assert [%{query: query}] = StripeStub.requests(:list_refunds)
      assert query["charge"] == payment.stripe_charge_id

      assert %{status: :succeeded, stripe_refund_id: "re_MADE"} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    end

    test "a stored 5xx is not replayed: the next attempt re-reads and uses a new key",
         %{payment: payment} do
      StripeStub.expect(:create_refund, {:error_fixture, "api_error"})

      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])

      StripeStub.expect(:list_refunds, StripeFixtures.list([]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_SECOND"))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      keys = Enum.map(StripeStub.requests(:create_refund), & &1.headers["idempotency-key"])
      assert keys == ["tymeslot:refund:#{refund.id}:1", "tymeslot:refund:#{refund.id}:2"]
      assert %{status: :succeeded, attempt: 2} = RefundQueries.get(refund.id)
    end

    test "a legacy key is replayed with its original request, naming no refund row",
         %{payment: payment} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          legacy_idempotency_key: "late_payment_refund:#{payment.id}:late:2000"
        )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LEGACY"))

      assert {:ok, %{status: :succeeded}} = Refunds.execute(refund, [])

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_refund)
      assert headers["idempotency-key"] == "late_payment_refund:#{payment.id}:late:2000"
      refute Map.has_key?(form["metadata"], "tymeslot_refund_id")
      assert form["metadata"]["booking_payment_id"] == payment.id
    end

    test "a legacy refund Stripe made under its old key is adopted, not made again",
         %{payment: payment} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          legacy_idempotency_key: "late_payment_refund:#{payment.id}:late:2000"
        )

      StripeStub.expect(:create_refund, {:error_fixture, "idempotency_error"})

      assert {:pending, _refund} = Refunds.execute(refund, [])

      old =
        StripeFixtures.object("refund_with_charge", %{
          "id" => "re_OLD",
          "amount" => 2_000,
          "metadata" => %{"booking_payment_id" => payment.id},
          "charge" => %{"amount_refunded" => 2_000}
        })

      other_amount =
        StripeFixtures.object("refund", %{
          "id" => "re_OTHER_AMOUNT",
          "amount" => 1_000,
          "metadata" => %{"booking_payment_id" => payment.id}
        })

      StripeStub.expect(:list_refunds, StripeFixtures.list([other_amount, old]))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert [_only_the_first] = StripeStub.requests(:create_refund)
      assert %{status: :succeeded, stripe_refund_id: "re_OLD"} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    end

    test "a legacy refund already recorded on another row is not adopted again",
         %{payment: payment} do
      payment =
        Repo.update!(
          Changeset.change(payment, status: :partially_refunded, refunded_amount_cents: 2_000)
        )

      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 2_000,
        status: :succeeded,
        stripe_refund_id: "re_RECORDED"
      )

      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          attempt: 1,
          legacy_idempotency_key: "host_refund:#{payment.id}:2000:2000"
        )

      # Stripe's total leaves 2_000 unrecorded, but the only refund that
      # could be this one is another row's.
      recorded = legacy_refund("re_RECORDED", payment, amount_refunded: 4_000)
      StripeStub.expect(:list_refunds, StripeFixtures.list([recorded]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_FRESH", 2_000))

      assert {:ok, %{stripe_refund_id: "re_FRESH"}} = Refunds.execute(refund, [])
    end

    test "a legacy refund Stripe's total has no unrecorded money for is not adopted",
         %{payment: payment} do
      payment =
        Repo.update!(
          Changeset.change(payment, status: :partially_refunded, refunded_amount_cents: 2_000)
        )

      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          attempt: 1,
          legacy_idempotency_key: "host_refund:#{payment.id}:2000:2000"
        )

      # A refund recorded before rows existed: Stripe's total holds nothing more.
      earlier = legacy_refund("re_EARLIER", payment, amount_refunded: 2_000)
      StripeStub.expect(:list_refunds, StripeFixtures.list([earlier]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_FRESH", 2_000))

      assert {:ok, %{stripe_refund_id: "re_FRESH"}} = Refunds.execute(refund, [])
      assert %{refunded_amount_cents: 4_000} = Repo.reload!(payment)
    end

    test "a permanent refusal fails the refund and alerts", %{payment: payment} do
      StripeStub.expect(
        :create_refund,
        StripeFixtures.error_body("invalid_request_error", %{"code" => "charge_already_refunded"})
      )

      assert {:error, :refund_failed} = Refunds.refund_now(payment, 2_000, :host, [])

      assert [refund] = RefundQueries.list_for_payment(payment.id)
      assert %{status: :failed, failure_code: "charge_already_refunded"} = refund
      refund_id = refund.id
      payment_id = payment.id

      assert_received {:send_alert, :refund_failed,
                       %{
                         refund_id: ^refund_id,
                         booking_payment_id: ^payment_id,
                         failure_code: "charge_already_refunded"
                       }}

      refute_received {:send_alert, :refund_failed, _payload}
      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "a payment without a charge id is backfilled first", %{payment: payment} do
      payment =
        payment
        |> Changeset.change(stripe_charge_id: nil, stripe_payment_intent_id: "pi_OUTBOX")
        |> Repo.update!()

      StripeStub.expect(
        :retrieve_payment_intent,
        StripeStubResponses.payment_intent("pi_OUTBOX", "ch_OUTBOX")
      )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_BACKFILLED"))

      assert {:ok, %{status: :succeeded}} = Refunds.refund_now(payment, 1_000, :host, [])

      assert [:retrieve_payment_intent, :create_refund] =
               Enum.map(StripeStub.requests(), & &1.operation)

      assert [%{form: %{"charge" => "ch_OUTBOX"}}] = StripeStub.requests(:create_refund)
    end
  end

  defp legacy_refund(id, payment, amount_refunded: total) do
    StripeFixtures.object("refund_with_charge", %{
      "id" => id,
      "amount" => 2_000,
      "metadata" => %{"booking_payment_id" => payment.id},
      "charge" => %{"amount_refunded" => total}
    })
  end

  describe "execute/2" do
    test "executing a settled refund calls nothing", %{payment: payment} do
      StripeStub.stub(:create_refund, StripeStubResponses.refund("re_UNASKED"))

      settled =
        insert(:booking_payment_refund,
          booking_payment: payment,
          status: :succeeded,
          stripe_refund_id: "re_DONE",
          attempt: 1
        )

      failed = insert(:booking_payment_refund, booking_payment: payment, status: :failed)

      assert {:ok, %{id: settled_id}} = Refunds.execute(settled, [])
      assert settled_id == settled.id
      assert {:error, :refund_failed} = Refunds.execute(failed, [])
      assert StripeStub.requests() == []
    end

    test "execute raises inside a transaction", %{payment: payment} do
      refund = insert(:booking_payment_refund, booking_payment: payment)

      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> Refunds.execute(refund, []) end)
      end
    end
  end
end
