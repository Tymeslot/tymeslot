defmodule Tymeslot.MeetingPayments.RefundOutboxConcurrencyTest do
  # async: false so the Ecto sandbox runs in shared mode (all processes share
  # the test's connection); the Tasks reach the Stripe stub through their
  # `$callers`.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses

  setup do
    %{payment: insert(:paid_booking_payment, stripe_account_id: "acct_CONCURRENT")}
  end

  test "two concurrent full refunds create one refund", %{payment: payment} do
    results =
      1..2
      |> Enum.map(fn _i ->
        Task.async(fn -> Refunds.request_refund(payment, payment.amount_cents, :host, []) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, _refund}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :refund_in_progress})) == 1
    assert [_one] = RefundQueries.list_for_payment(payment.id)
  end

  test "two executors of one refund send one create", %{payment: payment} do
    {:ok, refund} = Refunds.request_refund(payment, 2_000, :host, [])
    test_pid = self()

    # The first executor's create waits until the second executor has run,
    # so the second finds the lease held.
    StripeStub.expect(:create_refund, fn request ->
      send(test_pid, {:creating, self()})

      receive do
        :answer -> StripeStubResponses.refund(request, "re_ONCE")
      end
    end)

    first = Task.async(fn -> Refunds.execute(refund, []) end)
    assert_receive {:creating, creator}, 5_000

    second = Task.async(fn -> Refunds.execute(refund, []) end)
    assert {:pending, _refund} = Task.await(second, 5_000)

    send(creator, :answer)
    assert {:ok, %{status: :succeeded}} = Task.await(first, 5_000)

    assert [_one] = StripeStub.requests(:create_refund)
    assert %{status: :succeeded, attempt: 1} = RefundQueries.get(refund.id)
    assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
  end

  test "an expired lease is taken over", %{payment: payment} do
    refund =
      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 2_000,
        attempt: 1,
        executing_until: DateTime.add(DateTime.utc_now(:second), -1, :second)
      )

    StripeStub.expect(:list_refunds, StripeFixtures.list([]))
    StripeStub.expect(:create_refund, StripeStubResponses.refund("re_TAKEN_OVER"))

    assert {:ok, %{status: :succeeded, attempt: 2}} = Refunds.execute(refund, [])

    assert [:list_refunds, :create_refund] = Enum.map(StripeStub.requests(), & &1.operation)

    assert [%{headers: %{"idempotency-key" => key}}] = StripeStub.requests(:create_refund)
    assert key == "tymeslot:refund:#{refund.id}:2"
  end
end
