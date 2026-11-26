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
  import Tymeslot.Test.ClockHelpers

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias Tymeslot.Workers.SendRefundFailed

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

    test "every source the refund schema accepts for a request can be requested",
         %{payment: payment} do
      for source <- RefundSchema.requestable_sources() do
        assert {:ok, %{source: ^source}} = Refunds.request_refund(payment, 500, source, [])
      end
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

  describe "request_remaining_refund/2" do
    test "records a refund of what is left, its job due at once, without calling Stripe",
         %{payment: payment} do
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 1_000)

      assert {:ok, %RefundSchema{amount_cents: 4_000, source: :late_payment} = refund} =
               Refunds.request_remaining_refund(payment, :late_payment)

      assert StripeStub.requests() == []
      assert [job] = all_enqueued(worker: ExecuteRefund, args: %{"refund_id" => refund.id})
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
    end

    test "records nothing when pending refunds hold all that is left", %{payment: payment} do
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 5_000)

      assert {:ok, :none} = Refunds.request_remaining_refund(payment, :late_payment)
      assert RefundQueries.pending_cents(payment.id) == 5_000
    end

    test "records nothing for a payment it may not refund, inside the caller's transaction",
         %{payment: payment} do
      stale =
        payment
        |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day))
        |> Repo.update!()

      assert {:ok, :none} =
               Repo.transaction(fn ->
                 {:ok, :none} = Refunds.request_remaining_refund(stale, :late_payment)
                 :none
               end)

      assert RefundQueries.list_for_payment(payment.id) == []
    end

    # Stripe refuses to refund a disputed charge, so nothing is sent, but the
    # refund owed is on record for the dispute's close.
    test "records a disputed payment's refund failed, with no job, inside the caller's transaction",
         %{payment: payment} do
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 1_000)
      disputed = payment |> Changeset.change(status: :disputed) |> Repo.update!()

      assert {:ok, :none} =
               Repo.transaction(fn ->
                 {:ok, :none} = Refunds.request_remaining_refund(disputed, :late_payment)
                 :none
               end)

      assert [%{amount_cents: 4_000, source: :late_payment, failure_code: "under_dispute"} = held] =
               payment.id
               |> RefundQueries.list_for_payment()
               |> Enum.filter(&(&1.status == :failed))

      assert held.settled_at
      assert RefundQueries.pending_cents(payment.id) == 1_000
      refute_enqueued(worker: ExecuteRefund, args: %{"refund_id" => held.id})
      assert StripeStub.requests() == []
    end
  end

  describe "pending_refund_cents/1 and refund_pending?/1" do
    test "read the payment's pending refunds, settled ones aside", %{payment: payment} do
      refute Refunds.refund_pending?(payment)

      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 1_200)

      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 300,
        status: :failed
      )

      # Loaded without its pending refunds, as a lookup by id is.
      reloaded = Repo.reload!(payment)
      assert Refunds.pending_refund_cents(reloaded) == 1_200
      assert Refunds.refund_pending?(reloaded)

      # As listed, with them read in the same query.
      assert Refunds.pending_refund_cents(%{payment | pending_refund_cents: 700}) == 700
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

      other = "refund" |> StripeFixtures.object(%{"id" => "re_OTHER"}) |> Map.put("metadata", %{})
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

      # Once Stripe has had time to list a refund the 5xx'd request made.
      freeze_clock(DateTime.add(RefundQueries.get(refund.id).updated_at, 10 * 60, :second))
      StripeStub.expect(:list_refunds, StripeFixtures.list([]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_SECOND"))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      keys = Enum.map(StripeStub.requests(:create_refund), & &1.headers["idempotency-key"])
      assert keys == ["tymeslot:refund:#{refund.id}:1", "tymeslot:refund:#{refund.id}:2"]
      assert %{status: :succeeded, attempt: 2} = RefundQueries.get(refund.id)
    end

    test "a refund whose charge Stripe refuses to list for good stays pending, reported stuck",
         %{payment: payment} do
      refund = insert(:booking_payment_refund, booking_payment: payment, attempt: 1)

      StripeStub.expect(
        :list_refunds,
        {403, %{"error" => %{"type" => "invalid_request_error", "code" => "account_invalid"}}}
      )

      assert {:stuck, _refund} = Refunds.execute(refund, [])

      assert StripeStub.requests(:create_refund) == []
      assert %{status: :pending, executing_until: nil} = RefundQueries.get(refund.id)
      refund_id = refund.id
      assert_received {:send_alert, :refund_stuck, %{refund_id: ^refund_id}}
      refute_received {:send_alert, :refund_failed, _payload}
    end

    test "a refund whose list a refused API key blocks is retried, unreported",
         %{payment: payment} do
      refund = insert(:booking_payment_refund, booking_payment: payment, attempt: 1)

      StripeStub.expect(
        :list_refunds,
        {401, %{"error" => %{"type" => "invalid_request_error", "message" => "Invalid API Key"}}}
      )

      assert {:pending, _refund} = Refunds.execute(refund, from_job: true)

      assert StripeStub.requests(:create_refund) == []
      assert %{status: :pending, executing_until: nil} = RefundQueries.get(refund.id)
      refute_received {:send_alert, _type, _payload}
    end

    test "a refund whose create a refused API key blocks stays pending under its key, unreported",
         %{payment: payment} do
      StripeStub.expect(
        :create_refund,
        {401, %{"error" => %{"type" => "invalid_request_error", "message" => "Invalid API Key"}}}
      )

      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])

      assert %{status: :pending, executing_until: nil, key_attempt: key_attempt} =
               RefundQueries.get(refund.id)

      assert key_attempt == refund.key_attempt
      refute_received {:send_alert, _type, _payload}
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
      assert_enqueued(worker: SendRefundFailed, args: %{refund_id: refund_id})
    end

    # Nobody acted on these: the admins are told, the host is not emailed.
    for source <- [:late_payment, :approval_release] do
      test "a #{source} refund that fails alerts the admins only", %{payment: payment} do
        StripeStub.expect(:create_refund, {:error_fixture, "invalid_request_error"})

        assert {:error, :refund_failed} = Refunds.refund_now(payment, 2_000, unquote(source), [])

        assert_received {:send_alert, :refund_failed, %{source: unquote(source)}}
        refute_enqueued(worker: SendRefundFailed)
      end
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

  # Its metadata replaces the fixture's: a refund sent under a legacy key
  # names its payment and no refund row.
  defp legacy_refund(id, payment, created_at) do
    "refund_with_charge"
    |> StripeFixtures.object(%{
      "id" => id,
      "amount" => 2_000,
      "created" => DateTime.to_unix(created_at),
      "charge" => %{"amount_refunded" => 2_000}
    })
    |> Map.put("metadata", %{"booking_payment_id" => payment.id})
  end

  describe "a refund with a legacy key" do
    setup %{payment: payment} do
      %{key: "late_payment_refund:#{payment.id}:late:2000", now: DateTime.utc_now()}
    end

    test "is replayed with its original request, naming no refund row, while Stripe keeps it",
         %{payment: payment, key: key, now: now} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          legacy_idempotency_key: key,
          legacy_since: now
        )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LEGACY"))

      assert {:ok, %{status: :succeeded}} = Refunds.execute(refund, [])

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_refund)
      assert headers["idempotency-key"] == key
      refute Map.has_key?(form["metadata"], "tymeslot_refund_id")
      assert form["metadata"]["booking_payment_id"] == payment.id
    end

    test "is replayed again after an ambiguous attempt, even once the webhook recorded it",
         %{payment: payment, key: key, now: now} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          legacy_idempotency_key: key,
          legacy_since: now
        )

      first_attempt = :counters.new(1, [])

      StripeStub.stub(:create_refund, fn request ->
        :counters.add(first_attempt, 1, 1)

        if :counters.get(first_attempt, 1) <= 3,
          do: {:transport_error, :timeout},
          else: StripeStubResponses.refund(request, "re_LEGACY")
      end)

      assert {:pending, _refund} = Refunds.execute(refund, [])

      # `charge.refunded` records the refund Stripe made meanwhile.
      payment =
        Repo.update!(
          Changeset.change(payment, status: :partially_refunded, refunded_amount_cents: 2_000)
        )

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert StripeStub.requests(:list_refunds) == []
      keys = Enum.map(StripeStub.requests(:create_refund), & &1.headers["idempotency-key"])
      assert Enum.uniq(keys) == [key]
      assert %{status: :succeeded, stripe_refund_id: "re_LEGACY"} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    end

    test "once Stripe may have dropped the key, adopts the refund it made since",
         %{payment: payment, key: key, now: now} do
      since = DateTime.add(now, -25, :hour)

      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          legacy_idempotency_key: key,
          legacy_since: since
        )

      made = legacy_refund("re_MADE_SINCE", payment, DateTime.add(since, 60, :second))
      StripeStub.expect(:list_refunds, StripeFixtures.list([made]))

      assert {:ok, %{stripe_refund_id: "re_MADE_SINCE"}} = Refunds.execute(refund, [])
      assert StripeStub.requests(:create_refund) == []
    end

    test "once Stripe may have dropped the key, a refund made before it is not adopted",
         %{payment: payment, key: key, now: now} do
      since = DateTime.add(now, -25, :hour)

      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          legacy_idempotency_key: key,
          legacy_since: since
        )

      older = legacy_refund("re_OLDER", payment, DateTime.add(since, -1, :hour))
      StripeStub.expect(:list_refunds, StripeFixtures.list([older]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_FRESH"))

      assert {:ok, %{stripe_refund_id: "re_FRESH"}} = Refunds.execute(refund, [])
    end

    test "once Stripe may have dropped the key, a refund already on a row is not adopted",
         %{payment: payment, key: key, now: now} do
      since = DateTime.add(now, -25, :hour)

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
          legacy_idempotency_key: key,
          legacy_since: since
        )

      recorded = legacy_refund("re_RECORDED", payment, DateTime.add(since, 60, :second))
      StripeStub.expect(:list_refunds, StripeFixtures.list([recorded]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_FRESH"))

      assert {:ok, %{stripe_refund_id: "re_FRESH"}} = Refunds.execute(refund, [])
    end

    test "once Stripe may have dropped the key, with nothing to adopt, is made under the attempt's key",
         %{payment: payment, key: key, now: now} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          legacy_idempotency_key: key,
          legacy_since: DateTime.add(now, -25, :hour)
        )

      StripeStub.expect(:list_refunds, StripeFixtures.list([]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_FRESH"))

      assert {:ok, %{stripe_refund_id: "re_FRESH"}} = Refunds.execute(refund, [])

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_refund)
      assert headers["idempotency-key"] == "tymeslot:refund:#{refund.id}:1"
      assert form["metadata"]["tymeslot_refund_id"] == refund.id
    end

    test "is refused without the time it could first have been sent", %{payment: payment} do
      changeset =
        RefundSchema.request_changeset(%RefundSchema{}, %{
          booking_payment_id: payment.id,
          amount_cents: 2_000,
          source: :late_payment,
          legacy_idempotency_key: "late_payment_refund:x"
        })

      refute changeset.valid?
      assert changeset.errors[:legacy_since]
    end
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
