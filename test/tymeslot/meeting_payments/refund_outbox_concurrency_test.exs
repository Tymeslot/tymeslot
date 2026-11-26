defmodule Tymeslot.MeetingPayments.RefundOutboxConcurrencyTest do
  # async: false so the Ecto sandbox runs in shared mode (all processes share
  # the test's connection); the Tasks reach the Stripe stub through their
  # `$callers`.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses

  setup :capture_admin_alerts

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

  test "an attempt taking over from one that died mid-request resends its key",
       %{payment: payment} do
    refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

    # The first attempt claimed the refund and died before Stripe answered.
    {:ok, _first} = RefundQueries.claim_attempt(refund)
    expire_lease(refund)

    StripeStub.expect(:list_refunds, StripeFixtures.list([]))
    StripeStub.expect(:create_refund, StripeStubResponses.refund("re_FIRST_REQUEST"))

    assert {:ok, %{status: :succeeded, attempt: 2}} = Refunds.execute(refund, [])

    assert [%{headers: %{"idempotency-key" => key}}] = StripeStub.requests(:create_refund)
    assert key == "tymeslot:refund:#{refund.id}:1"
  end

  describe "a claim outlived by its lease" do
    setup %{payment: payment} do
      refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)
      %{refund: refund}
    end

    test "a late release does not clear the next claim's lease", %{refund: refund} do
      {:ok, first} = RefundQueries.claim_attempt(refund)
      expire_lease(refund)
      {:ok, second} = RefundQueries.claim_attempt(refund)

      :ok = RefundQueries.release(first)

      assert %{attempt: 2, executing_until: %DateTime{}} = RefundQueries.get(refund.id)
      assert :busy = RefundQueries.claim_attempt(refund)
      :ok = RefundQueries.release(second)
      assert %{executing_until: nil} = RefundQueries.get(refund.id)
    end

    test "a late refusal does not fail a refund the next attempt is making",
         %{payment: payment, refund: refund} do
      test_pid = self()

      for {answer, n} <- [
            {StripeFixtures.error_body("charge_already_refunded"), 1},
            {&StripeStubResponses.refund(&1, "re_SECOND"), 2}
          ] do
        StripeStub.expect(:create_refund, fn request ->
          send(test_pid, {:creating, n, self()})

          receive do
            :answer -> if is_function(answer), do: answer.(request), else: answer
          end
        end)
      end

      StripeStub.expect(:list_refunds, StripeFixtures.list([]))

      first = Task.async(fn -> Refunds.execute(refund, []) end)
      assert_receive {:creating, 1, first_creator}, 5_000
      expire_lease(refund)

      second = Task.async(fn -> Refunds.execute(refund, []) end)
      assert_receive {:creating, 2, second_creator}, 5_000

      send(first_creator, :answer)
      assert {:pending, _refund} = Task.await(first, 5_000)
      assert %{status: :pending, failure_code: nil, attempt: 2} = RefundQueries.get(refund.id)

      send(second_creator, :answer)
      assert {:ok, %{status: :succeeded}} = Task.await(second, 5_000)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    end
  end

  test "a refund Stripe made is recorded over a failure settled meanwhile", %{payment: payment} do
    refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)
    test_pid = self()

    StripeStub.expect(:create_refund, fn request ->
      send(test_pid, {:creating, self()})

      receive do
        :answer -> StripeStubResponses.refund(request, "re_LATE_SUCCESS")
      end
    end)

    first = Task.async(fn -> Refunds.execute(refund, []) end)
    assert_receive {:creating, creator}, 5_000

    expire_lease(refund)
    {:ok, second} = RefundQueries.claim_attempt(refund)

    {:ok, _failed} =
      RefundQueries.settle_claimed(second, %{
        status: :failed,
        failure_code: "refund_failed",
        settled_at: DateTime.utc_now(:second)
      })

    send(creator, :answer)

    assert {:ok, %{status: :succeeded, stripe_refund_id: "re_LATE_SUCCESS", failure_code: nil}} =
             Task.await(first, 5_000)

    assert %{refunded_amount_cents: 2_000, status: :partially_refunded} = Repo.reload!(payment)

    refund_id = refund.id

    assert_received {:send_alert, :refund_failure_reversed,
                     %{
                       refund_id: ^refund_id,
                       failure_code: "refund_failed",
                       host_may_have_been_told: true
                     }}
  end

  test "a refund Stripe reported failed is not recorded as made from an older answer",
       %{payment: payment} do
    refund =
      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 2_000,
        status: :failed,
        failure_code: "refund_failed",
        stripe_refund_id: "re_ENDED",
        settled_at: DateTime.utc_now(:second)
      )

    attrs = %{status: :succeeded, stripe_refund_id: "re_ENDED", settled_at: DateTime.utc_now()}

    assert {:error, :not_pending} = RefundQueries.settle(refund, attrs)
    assert %{status: :failed, failure_code: "refund_failed"} = RefundQueries.get(refund.id)
  end

  test "two rows settling one Stripe refund: the second is refused, not raised",
       %{payment: payment} do
    first = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)
    second = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

    attrs = %{
      status: :succeeded,
      stripe_refund_id: "re_ONE",
      settled_at: DateTime.utc_now(:second)
    }

    assert {:ok, _settled} = RefundQueries.settle(first, attrs)
    assert {:error, :stripe_refund_taken} = RefundQueries.settle(second, attrs)
  end

  defp expire_lease(refund) do
    past = DateTime.add(DateTime.utc_now(:second), -3_600, :second)

    Repo.update_all(from(r in RefundSchema, where: r.id == ^refund.id),
      set: [executing_until: past]
    )
  end
end
