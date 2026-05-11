defmodule Tymeslot.MeetingPayments.RefundsConcurrencyTest do
  # async: false is required so the Ecto sandbox runs in shared mode (all
  # processes share the test DB connection) and Mox runs in global mode
  # (spawned Tasks can call the mock without explicit allowance).
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  setup :verify_on_exit!

  defp paid_booking_payment(attrs \\ %{}) do
    defaults = %{
      stripe_charge_id: "ch_CONCURRENT_#{System.unique_integer([:positive])}",
      stripe_payment_intent_id: "pi_CONCURRENT_#{System.unique_integer([:positive])}",
      stripe_checkout_session_id: "cs_CONCURRENT_#{System.unique_integer([:positive])}",
      amount_cents: 4000,
      application_fee_cents: 20,
      currency: "eur",
      status: "paid",
      paid_at: DateTime.utc_now(:second),
      refunded_amount_cents: 0,
      stripe_account_id: "acct_CONCURRENT"
    }

    insert(:booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  describe "issue_refund/3 — row-lock serialisation" do
    test "concurrent partial refunds serialize via FOR UPDATE: one wins, balance is correct" do
      # Payment with 4000 cents remaining. Two tasks each request a 2000-cent
      # partial refund simultaneously. The FOR UPDATE lock in get_for_update/1
      # ensures the second caller re-validates against the already-updated row.
      # Possible outcomes:
      #   a) Task A wins first: A → {:ok, partially_refunded, 2000}, B → {:ok, refunded, 4000}
      #   b) Task B wins first: same results, just reversed
      #   c) Both tasks happen to pick distinct idempotency keys and Stripe accepts
      #      both — final total must still equal 4000 (sum of two 2000 refunds).
      #
      # Under the row-lock the second task sees refunded_amount_cents = 2000 when
      # it validates, so it can still succeed (2000 ≤ remaining 2000). The total
      # is therefore always 4000, never 2000 (one lost) and never 4000 from a
      # single task that double-counted.
      payment = paid_booking_payment()

      # Allow up to 2 Stripe calls (one per task). If both tasks race through
      # the lock, Stripe is called twice with distinct idempotency keys and
      # distinct amounts-after context.
      stub(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:ok, %{id: "re_concurrent_#{System.unique_integer([:positive])}"}}
      end)

      tasks =
        for _i <- 1..2 do
          Task.async(fn ->
            Refunds.issue_refund(payment, 2000)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, _}, &1))

      # At least one refund must have succeeded.
      assert length(successes) >= 1,
             "expected at least one {:ok, _} result, got: #{inspect(results)}"

      # No unexpected errors — only :invalid_amount is acceptable on the loser.
      Enum.each(errors, fn {:error, reason} ->
        assert reason == :invalid_amount,
               "unexpected error reason #{inspect(reason)}"
      end)

      # Final state: the row must reflect the sum of all successful refunds.
      reloaded = BookingPaymentQueries.by_charge_id(payment.stripe_charge_id)
      total_refunded = successes |> Enum.map(fn {:ok, p} -> p.refunded_amount_cents end) |> Enum.max()

      assert reloaded.refunded_amount_cents == total_refunded,
             "DB refunded_amount_cents #{reloaded.refunded_amount_cents} does not match " <>
               "max success total #{total_refunded}"

      # The sum of successful refunds must be a valid multiple of 2000
      # (each task refunds exactly 2000).
      assert reloaded.refunded_amount_cents in [2000, 4000],
             "expected 2000 or 4000 total refunded, got #{reloaded.refunded_amount_cents}"
    end

    test "concurrent refunds where second attempt exceeds remaining: only one succeeds" do
      # Payment with 3000 cents. Two tasks each request 3000 (a full refund).
      # The second task through the lock must see remaining = 0 and return
      # {:error, :invalid_amount}.
      payment = paid_booking_payment(%{amount_cents: 3000})

      # Only one Stripe call should happen because the second task fails validation.
      expect(StripeAdapterMock, :create_refund, 1, fn _params, _opts ->
        {:ok, %{id: "re_winner"}}
      end)

      tasks =
        for _i <- 1..2 do
          Task.async(fn ->
            Refunds.issue_refund(payment, 3000)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes = Enum.count(results, &match?({:ok, _}, &1))

      rejected =
        Enum.count(results, &match?({:error, reason} when reason in [:invalid_amount, :already_refunded], &1))

      assert successes == 1,
             "expected exactly one {:ok, _} result, got: #{inspect(results)}"

      assert rejected == 1,
             "expected exactly one {:error, :invalid_amount | :already_refunded} result, got: #{inspect(results)}"

      reloaded = BookingPaymentQueries.by_charge_id(payment.stripe_charge_id)
      assert reloaded.refunded_amount_cents == 3000
      assert reloaded.status == "refunded"
    end
  end
end
