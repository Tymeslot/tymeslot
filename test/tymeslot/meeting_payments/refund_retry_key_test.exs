defmodule Tymeslot.MeetingPayments.RefundRetryKeyTest do
  @moduledoc """
  Which idempotency key a refund's next attempt sends: the same key while
  Stripe has stored no answer under it, so a refund Stripe made without its
  answer arriving is returned rather than made twice, and a new one, later,
  once Stripe has stored an answer a resend would only replay.
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

  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.SendRefundFailed

  setup :capture_admin_alerts

  setup do
    host = insert(:user)

    payment =
      insert(:paid_booking_payment, host_user_id: host.id, stripe_account_id: "acct_RETRY_KEY")

    %{payment: payment}
  end

  # Stripe made the refund under the first attempt's key, and its list of the
  # charge's refunds does not show it yet. A request under that key is
  # answered with the refund it made, as Stripe replays a key; one under any
  # other key gets `other_key.(request)`.
  defp made_under_first_key(refund, other_key) do
    first_key = "tymeslot:refund:#{refund.id}:1"
    StripeStub.stub(:list_refunds, StripeFixtures.list([]))

    StripeStub.stub(:create_refund, fn request ->
      if request.headers["idempotency-key"] == first_key,
        do: StripeStubResponses.refund(request, "re_MADE"),
        else: other_key.(request)
    end)
  end

  defp create_keys,
    do: :create_refund |> StripeStub.requests() |> Enum.map(& &1.headers["idempotency-key"])

  # Moves the clock past the wait a refund serves after an attempt that gave
  # up its key, so its job attempts it.
  defp settle_window_passed(refund) do
    attempted_at = RefundQueries.get(refund.id).updated_at
    freeze_clock(DateTime.add(attempted_at, 10 * 60, :second))
  end

  describe "a request whose answer never arrived" do
    test "is sent again under its own key, which records the refund it made",
         %{payment: payment} do
      StripeStub.stub(:create_refund, {:transport_error, :timeout})
      assert {:pending, refund} = Refunds.refund_now(payment, 5_000, :host, [])

      made_under_first_key(refund, fn _request ->
        StripeFixtures.error_body("charge_already_refunded")
      end)

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert Enum.uniq(create_keys()) == ["tymeslot:refund:#{refund.id}:1"]
      assert [_listed] = StripeStub.requests(:list_refunds)

      assert %{status: :succeeded, stripe_refund_id: "re_MADE", failure_code: nil} =
               RefundQueries.get(refund.id)

      assert %{refunded_amount_cents: 5_000, status: :refunded} = Repo.reload!(payment)
      refute_enqueued(worker: SendRefundFailed)
      refute_received {:send_alert, :refund_failed, _payload}
    end

    test "a partial refund the balance still covers is made at Stripe once",
         %{payment: payment} do
      StripeStub.stub(:create_refund, {:transport_error, :timeout})
      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])

      made_under_first_key(refund, &StripeStubResponses.refund(&1, "re_SECOND"))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert Enum.uniq(create_keys()) == ["tymeslot:refund:#{refund.id}:1"]
      assert %{status: :succeeded, stripe_refund_id: "re_MADE"} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    end

    test "keeps its key through attempts Stripe answers with a conflict",
         %{payment: payment} do
      refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

      StripeStub.stub(:list_refunds, StripeFixtures.list([]))
      StripeStub.expect(:create_refund, 3, {:transport_error, :timeout})
      # Stripe still working on the first request under that key.
      StripeStub.expect(
        :create_refund,
        3,
        {409, %{"error" => %{"type" => "idempotency_error", "message" => "in progress"}}}
      )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_MADE"))

      assert {:pending, _refund} = Refunds.execute(refund, from_job: true)
      assert {:pending, _refund} = Refunds.execute(refund, from_job: true)
      assert {:ok, %{status: :succeeded, attempt: 3}} = Refunds.execute(refund, from_job: true)

      assert Enum.uniq(create_keys()) == ["tymeslot:refund:#{refund.id}:1"]
    end

    test "a refusal of the resent key still fails the refund and tells the host",
         %{payment: payment} do
      StripeStub.stub(:create_refund, {:transport_error, :timeout})
      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])

      StripeStub.stub(:list_refunds, StripeFixtures.list([]))
      StripeStub.stub(:create_refund, {:error_fixture, "card_error"})

      assert {:cancel, :refund_failed} = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert Enum.uniq(create_keys()) == ["tymeslot:refund:#{refund.id}:1"]
      assert %{status: :failed, failure_code: "card_declined"} = RefundQueries.get(refund.id)
      assert_enqueued(worker: SendRefundFailed, args: %{refund_id: refund.id})
    end
  end

  describe "a request Stripe answered with a stored 5xx" do
    test "is followed by a later attempt under a new key, not at once", %{payment: payment} do
      StripeStub.expect(:create_refund, {:error_fixture, "api_error"})

      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])

      assert [job] = all_enqueued(worker: ExecuteRefund, args: %{"refund_id" => refund.id})
      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second), 600, 5
    end

    # The job's own backoff would run the next attempt a minute later.
    test "the next attempt waits ten minutes from the failed one, spending no attempt",
         %{payment: payment} do
      StripeStub.expect(:create_refund, {:error_fixture, "api_error"})
      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])
      attempted_at = RefundQueries.get(refund.id).updated_at

      freeze_clock(DateTime.add(attempted_at, 60, :second))
      assert {:snooze, 540} = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 2)

      freeze_clock(DateTime.add(attempted_at, 599, :second))
      assert {:snooze, 1} = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 2)

      assert StripeStub.requests(:list_refunds) == []
      assert [_first] = StripeStub.requests(:create_refund)
      assert %{attempt: 1} = RefundQueries.get(refund.id)

      freeze_clock(DateTime.add(attempted_at, 600, :second))
      StripeStub.expect(:list_refunds, StripeFixtures.list([]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LATER"))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 2)
      assert create_keys() == ["tymeslot:refund:#{refund.id}:1", "tymeslot:refund:#{refund.id}:2"]
    end

    test "an attempt that kept its key does not wait", %{payment: payment} do
      # The client tries an unanswered request three times.
      StripeStub.expect(:create_refund, 3, {:transport_error, :timeout})
      assert {:pending, refund} = Refunds.refund_now(payment, 2_000, :host, [])

      StripeStub.expect(:list_refunds, StripeFixtures.list([]))
      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_AT_ONCE"))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 2)
    end

    test "a later refusal saying the charge is refunded waits for Stripe's list",
         %{payment: payment} do
      StripeStub.expect(:create_refund, {:error_fixture, "api_error"})
      assert {:pending, refund} = Refunds.refund_now(payment, 5_000, :host, [])

      # The 5xx'd request made the refund, which Stripe does not list yet.
      settle_window_passed(refund)
      StripeStub.expect(:list_refunds, StripeFixtures.list([]))
      StripeStub.expect(:create_refund, {:error_fixture, "charge_already_refunded"})

      assert {:error, :pending} = perform_job(ExecuteRefund, %{refund_id: refund.id})
      assert %{status: :pending, failure_code: nil} = RefundQueries.get(refund.id)
      refute_enqueued(worker: SendRefundFailed)

      settle_window_passed(refund)

      made =
        StripeFixtures.object("refund_with_charge", %{
          "id" => "re_MADE",
          "amount" => 5_000,
          "metadata" => %{"tymeslot_refund_id" => refund.id},
          "charge" => %{"amount_refunded" => 5_000}
        })

      StripeStub.expect(:list_refunds, StripeFixtures.list([made]))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

      assert create_keys() == ["tymeslot:refund:#{refund.id}:1", "tymeslot:refund:#{refund.id}:2"]
      assert %{status: :succeeded, stripe_refund_id: "re_MADE"} = RefundQueries.get(refund.id)
      refute_enqueued(worker: SendRefundFailed)
    end
  end
end
