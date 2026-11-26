defmodule Tymeslot.MeetingPayments.Workers.ExecuteRefundTest do
  # async: false: admin alerts are captured through application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :capture_log

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers, only: [with_config: 2]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Telemetry, as: MeetingPaymentsTelemetry
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.MeetingPayments.Workers.SweepPendingRefunds
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses

  setup :capture_admin_alerts

  setup do
    payment = insert(:paid_booking_payment, stripe_account_id: "acct_JOB")
    {:ok, refund} = Refunds.request_refund(payment, 2_000, :late_payment, [])
    %{payment: payment, refund: refund}
  end

  test "makes the refund", %{payment: payment, refund: refund} do
    StripeStub.expect(:create_refund, StripeStubResponses.refund("re_JOB"))
    status_changed = MeetingPaymentsTelemetry.status_changed_event()
    ref = :telemetry_test.attach_event_handlers(self(), [status_changed])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

    assert_received {^status_changed, ^ref, %{count: 1},
                     %{from: :paid, to: :partially_refunded, reason: :late_payment_refund}}

    assert %{status: :succeeded} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
  end

  test "an attempt that leaves the refund pending is retried quietly", %{refund: refund} do
    StripeStub.expect(:create_refund, {:error_fixture, "api_error"})

    assert {:error, :pending} = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 1)

    assert %{status: :pending, executing_until: nil} = RefundQueries.get(refund.id)
    refute_received {:send_alert, _type, _payload}
  end

  # A Stripe timeout leaves the refund pending and the job retries it: a wait,
  # not an error worth tracking.
  test "an attempt that leaves the refund pending records no error", %{refund: refund} do
    with_config(:error_tracker, enabled: true)
    StripeStub.expect(:create_refund, {:error_fixture, "api_error"})

    assert {:error, :pending} = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 1)

    assert Repo.all(ErrorTracker.Error) == []
  end

  test "the last attempt fails a refund Stripe never made, without asking for it",
       %{refund: refund} do
    StripeStub.stub(:create_refund, StripeStubResponses.refund("re_UNASKED"))
    StripeStub.expect(:list_refunds, StripeFixtures.list([]))

    assert {:cancel, :refund_failed} =
             perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 10)

    assert StripeStub.requests(:create_refund) == []
    assert %{status: :failed, failure_code: "retries_exhausted"} = RefundQueries.get(refund.id)

    refund_id = refund.id

    assert_received {:send_alert, :refund_failed,
                     %{refund_id: ^refund_id, failure_code: "retries_exhausted"}}
  end

  test "the last attempt adopts a refund an ambiguous timeout left made at Stripe",
       %{payment: payment, refund: refund} do
    StripeStub.stub(:create_refund, {:transport_error, :timeout})
    assert {:error, :pending} = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 9)
    creates = StripeStub.requests(:create_refund)

    made =
      StripeFixtures.object("refund_with_charge", %{
        "id" => "re_LAST",
        "amount" => 2_000,
        "metadata" => %{"tymeslot_refund_id" => refund.id},
        "charge" => %{"amount_refunded" => 2_000}
      })

    StripeStub.expect(:list_refunds, StripeFixtures.list([made]))

    assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 10)

    assert StripeStub.requests(:create_refund) == creates
    assert %{status: :succeeded, stripe_refund_id: "re_LAST"} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    refute_received {:send_alert, _type, _payload}
  end

  test "the last attempt that cannot read Stripe's refunds reports the refund stuck",
       %{refund: refund} do
    StripeStub.stub(:list_refunds, {:error_fixture, "api_error"})

    assert {:error, :pending} = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 10)

    assert %{status: :pending} = RefundQueries.get(refund.id)
    refund_id = refund.id
    assert_received {:send_alert, :refund_stuck, %{refund_id: ^refund_id}}
    refute_received {:send_alert, :refund_failed, _payload}
  end

  test "the last attempt leaves a refund another attempt is making", %{refund: refund} do
    {:ok, _claimed} = RefundQueries.claim_attempt(refund)

    assert {:error, :pending} =
             perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 10)

    assert %{status: :pending} = RefundQueries.get(refund.id)
    refute_received {:send_alert, _type, _payload}
  end

  describe "a refund whose charge Stripe refuses to list" do
    # An earlier attempt's request went unanswered, so this one lists first.
    setup %{payment: payment} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          attempt: 1,
          key_attempt: 1,
          inserted_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)
        )

      StripeStub.stub(:list_refunds, {403, %{"error" => %{"type" => "invalid_request_error"}}})
      %{stuck: refund}
    end

    test "stays pending, reported, its job waiting fifteen minutes", %{stuck: refund} do
      assert {:snooze, 900} = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert %{status: :pending} = RefundQueries.get(refund.id)
      refund_id = refund.id
      assert_received {:send_alert, :refund_stuck, %{refund_id: ^refund_id}}
    end

    test "waits twice as long each time, up to a day", %{stuck: refund} do
      waits =
        for waited <- [1, 2, 6, 7, 20] do
          {:snooze, seconds} =
            perform_job(ExecuteRefund, %{refund_id: refund.id}, meta: %{"snoozed" => waited})

          seconds
        end

      assert waits == [1_800, 3_600, 57_600, 86_400, 86_400]
    end

    test "keeps the pending-refund sweep from giving it a second job", %{stuck: refund} do
      {:ok, _job} = Oban.insert(ExecuteRefund.new(%{refund_id: refund.id}))
      assert %{snoozed: 1} = Oban.drain_queue(queue: :payments)

      assert :ok = perform_job(SweepPendingRefunds, %{})
      assert :ok = perform_job(SweepPendingRefunds, %{})

      assert [%{state: "scheduled"}] =
               all_enqueued(worker: ExecuteRefund, args: %{refund_id: refund.id})

      assert [_one] = StripeStub.requests(:list_refunds)
    end

    test "is left alone once an operator settled it", %{stuck: refund} do
      assert {:snooze, _seconds} = perform_job(ExecuteRefund, %{refund_id: refund.id})
      calls = length(StripeStub.requests(:list_refunds))

      assert {:ok, _settled, :settled} = Refunds.settle_by_hand(refund, :failed)

      assert {:cancel, :refund_failed} = perform_job(ExecuteRefund, %{refund_id: refund.id})
      assert length(StripeStub.requests(:list_refunds)) == calls
    end
  end

  test "a refund Stripe refused cancels the job", %{refund: refund} do
    StripeStub.expect(:create_refund, {:error_fixture, "charge_already_refunded"})

    assert {:cancel, :refund_failed} = perform_job(ExecuteRefund, %{refund_id: refund.id})
  end

  test "a charge that cannot be found by the last attempt fails the refund",
       %{payment: payment, refund: refund} do
    payment
    |> Changeset.change(stripe_charge_id: nil, stripe_payment_intent_id: nil)
    |> Repo.update!()

    assert {:error, :pending} = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 1)

    assert {:cancel, :missing_charge} =
             perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 10)

    assert %{status: :failed, failure_code: "missing_charge"} = RefundQueries.get(refund.id)
    assert_received {:send_alert, :refund_failed, %{failure_code: "missing_charge"}}
  end

  test "a refund that no longer exists is discarded" do
    assert {:discard, :not_found} = perform_job(ExecuteRefund, %{refund_id: UUID.generate()})
  end

  test "reschedule replaces when the waiting job runs", %{refund: refund} do
    assert [%{scheduled_at: later}] = all_enqueued(worker: ExecuteRefund)
    assert DateTime.compare(later, DateTime.utc_now()) == :gt

    :ok = ExecuteRefund.reschedule(refund.id, in: 0)

    assert [%{scheduled_at: now}] = all_enqueued(worker: ExecuteRefund)
    assert DateTime.compare(now, DateTime.utc_now()) != :gt
  end
end
