defmodule Tymeslot.MeetingPayments.Workers.RefundLatePaymentTest do
  @moduledoc """
  The job that refunds a payment completing after its booking's slot was
  taken. The money is owed until Stripe accepts the refund, so the job must
  refund exactly once however its attempts end, email the attendee exactly
  once, and leave the booking where the host and an admin can see it when
  it gives up.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Mox, only: [expect: 3, stub: 3, verify_on_exit!: 1]
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Repo

  setup :verify_on_exit!
  setup :capture_admin_alerts

  setup do
    host = insert(:user)
    meeting = insert(:meeting, status: "expired", organizer_user_id: host.id)

    payment =
      insert(:paid_booking_payment,
        host_user_id: host.id,
        meeting: meeting,
        stripe_account_id: "acct_LATE"
      )

    %{host: host, payment: payment}
  end

  test "refunds the payment in full and emails the attendee once", %{payment: payment} do
    expect(StripeAdapterMock, :create_refund, fn params, opts ->
      assert params.charge == payment.stripe_charge_id
      assert params.amount == 5000
      assert opts[:connect_account] == "acct_LATE"
      assert opts[:idempotency_key] == "refund:#{payment.id}:5000:5000"
      assert opts[:connect_timeout] == 3_000
      assert opts[:recv_timeout] == 5_000
      {:ok, %{"id" => "re_LATE"}}
    end)

    assert :ok = perform(payment)

    assert Repo.reload!(payment).status == "refunded"
    assert refund_emails(payment) == 1
    refute_received {:send_alert, _type, _payload}
  end

  test "a failed attempt short of the last is retried quietly", %{payment: payment} do
    expect(StripeAdapterMock, :create_refund, fn _params, _opts -> {:error, :stripe_down} end)

    assert {:error, :stripe_down} = perform(payment, attempt: 3)

    assert Repo.reload!(payment).status == "paid"
    assert refund_emails(payment) == 0
    refute_received {:send_alert, _type, _payload}
  end

  test "a refund that fails on the last attempt alerts an admin and stays on the host's list",
       %{host: host, payment: payment} do
    expect(StripeAdapterMock, :create_refund, fn _params, _opts -> {:error, :stripe_down} end)

    assert {:error, :stripe_down} = perform(payment, attempt: 10)

    payment_id = payment.id

    assert_received {:send_alert, :late_payment_refund_failed,
                     %{booking_payment_id: ^payment_id} = alert}

    assert alert.summary =~ "could not be refunded"
    assert is_integer(alert.oban_job_id)
    assert Repo.reload!(payment).status == "paid"
    assert refund_emails(payment) == 0
    assert [%{id: ^payment_id}] = MeetingPayments.list_outstanding_refunds_for_host(host.id)
  end

  # The webhook commits the payment and this job even when it could not
  # fetch the charge id, so the job fetches it before refunding.
  test "backfills a missing charge id before refunding, retrying until Stripe supplies it",
       %{payment: payment} do
    payment
    |> Changeset.change(stripe_charge_id: nil, stripe_payment_intent_id: "pi_LATE")
    |> Repo.update!()

    expect(StripeAdapterMock, :retrieve_payment_intent, fn "pi_LATE", opts ->
      assert opts[:connect_account] == "acct_LATE"
      {:error, :stripe_down}
    end)

    assert {:error, :stripe_down} = perform(payment)
    assert is_nil(Repo.reload!(payment).stripe_charge_id)

    expect(StripeAdapterMock, :retrieve_payment_intent, fn "pi_LATE", _opts ->
      {:ok, %{"latest_charge" => %{"id" => "ch_BACKFILLED"}}}
    end)

    expect(StripeAdapterMock, :create_refund, fn params, _opts ->
      assert params.charge == "ch_BACKFILLED"
      {:ok, %{"id" => "re_LATE"}}
    end)

    assert :ok = perform(payment, attempt: 2)

    refunded = Repo.reload!(payment)
    assert refunded.stripe_charge_id == "ch_BACKFILLED"
    assert refunded.status == "refunded"
    assert refund_emails(payment) == 1
  end

  # The dispute decides where the money goes: an attendee who wins it has
  # it back, and a host who wins it finds the payment `paid` again and back
  # on the outstanding-refunds list.
  test "a disputed payment is left to the dispute at once, without retries or an alert",
       %{payment: payment} do
    payment |> Changeset.change(status: "disputed") |> Repo.update!()

    assert {:discard, :under_dispute} = perform(payment)

    assert Repo.reload!(payment).status == "disputed"
    assert refund_emails(payment) == 0
    refute_received {:send_alert, _type, _payload}
  end

  test "a payment past the refund window is left on the host's list at once",
       %{host: host, payment: payment} do
    paid_at = DateTime.add(DateTime.utc_now(:second), -61, :day)
    payment |> Changeset.change(paid_at: paid_at) |> Repo.update!()

    assert {:discard, :outside_refund_window} = perform(payment)

    payment_id = payment.id
    assert [%{id: ^payment_id}] = MeetingPayments.list_outstanding_refunds_for_host(host.id)
    refute_received {:send_alert, _type, _payload}
  end

  test "a payment with no paid time is left on the host's list at once",
       %{host: host, payment: payment} do
    payment |> Changeset.change(paid_at: nil) |> Repo.update!()

    assert {:discard, :not_paid} = perform(payment)

    payment_id = payment.id
    assert [%{id: ^payment_id}] = MeetingPayments.list_outstanding_refunds_for_host(host.id)
    refute_received {:send_alert, _type, _payload}
  end

  # The refusals need no charge id, so a payment still missing one is not
  # sent to Stripe for it first, only to be retried for hours while the
  # lookup fails.
  test "a refusal is discarded at once even while the charge id is missing",
       %{payment: payment} do
    stale = DateTime.add(DateTime.utc_now(:second), -61, :day)

    for {changes, reason} <- [
          {[status: "disputed"], :under_dispute},
          {[paid_at: stale], :outside_refund_window},
          {[paid_at: nil], :not_paid}
        ] do
      payment
      |> Changeset.change([stripe_charge_id: nil, stripe_payment_intent_id: "pi_LATE"] ++ changes)
      |> Repo.update!()

      assert {:discard, ^reason} = perform(payment)
      payment |> Changeset.change(status: "paid", paid_at: payment.paid_at) |> Repo.update!()
    end

    assert refund_emails(payment) == 0
    refute_received {:send_alert, _type, _payload}
  end

  test "the discarded refusals are expected outcomes, not failures to record" do
    for reason <- [:not_paid, :outside_refund_window, :under_dispute] do
      assert RefundLatePayment.expected_outcome?(reason)
    end

    refute RefundLatePayment.expected_outcome?(:stripe_down)
  end

  # Stripe accepts the refund, then the transaction that records it dies
  # before committing. The retry asks again under the same idempotency key,
  # so Stripe hands back the refund it already made instead of a second one.
  test "a refund Stripe accepted before the job's transaction rolled back is not made twice",
       %{payment: payment} do
    stripe = start_supervised!({Agent, fn -> %{refunds: %{}, keys: []} end})

    stub(StripeAdapterMock, :create_refund, fn params, opts ->
      key = opts[:idempotency_key]

      first? =
        Agent.get_and_update(stripe, fn state ->
          refunds = Map.put_new(state.refunds, key, params.amount)
          {not Map.has_key?(state.refunds, key), %{refunds: refunds, keys: [key | state.keys]}}
        end)

      if first?, do: raise(DBConnection.ConnectionError, "connection lost")
      {:ok, %{"id" => "re_#{key}"}}
    end)

    assert {:error, %DBConnection.ConnectionError{}} = perform(payment)
    assert Repo.reload!(payment).status == "paid"
    assert refund_emails(payment) == 0

    assert :ok = perform(payment, attempt: 2)

    %{refunds: refunds, keys: keys} = Agent.get(stripe, & &1)
    assert map_size(refunds) == 1
    assert [key, key] = keys
    assert Repo.reload!(payment).status == "refunded"
    assert refund_emails(payment) == 1
  end

  # As above, but Stripe's `charge.refunded` recorded the refund before the
  # retry ran: the retry finds the payment refunded and only the email is
  # left to send.
  test "emails the attendee when the refund was recorded by Stripe's webhook instead",
       %{payment: payment} do
    record_refunded(payment)

    assert :ok = perform(payment, attempt: 2)

    assert refund_emails(payment) == 1
  end

  test "sends no second email when the refund was already emailed", %{payment: payment} do
    expect(StripeAdapterMock, :create_refund, fn _params, _opts -> {:ok, %{"id" => "re_HOST"}} end)

    {:ok, _refunded} = Refunds.issue_host_refund(payment.id, payment.host_user_id, 5000)
    complete_emails(payment)

    assert :ok = perform(payment, attempt: 2)

    assert refund_emails(payment) == 1
  end

  # Even a job that gave up for good: the payment is then the host's and an
  # admin's to settle, never a second automatic refund's.
  test "is scheduled at most once per payment, whatever became of the first job",
       %{payment: payment} do
    {:ok, first} = Oban.insert(RefundLatePayment.new_for(payment.id))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [state: "discarded"])

    {:ok, second} = Oban.insert(RefundLatePayment.new_for(payment.id))

    assert second.conflict?
    assert second.id == first.id
  end

  # The first job, discarded while a dispute held the money, must not
  # swallow the one a won dispute schedules; that one is unique in turn.
  test "is scheduled once more, and only once, after a won dispute", %{payment: payment} do
    {:ok, first} = Oban.insert(RefundLatePayment.new_for(payment.id))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [state: "discarded"])

    {:ok, after_dispute} = Oban.insert(RefundLatePayment.new_after_dispute(payment.id))
    refute after_dispute.conflict?

    {:ok, again} = Oban.insert(RefundLatePayment.new_after_dispute(payment.id))
    assert again.conflict?
    assert again.id == after_dispute.id
  end

  test "spreads its attempts over about four hours, inside Stripe's idempotency window" do
    total =
      Enum.sum(for attempt <- 1..9, do: RefundLatePayment.backoff(%Oban.Job{attempt: attempt}))

    assert total == 14_580
  end

  defp perform(payment, opts \\ []) do
    perform_job(RefundLatePayment, %{booking_payment_id: payment.id},
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: 10
    )
  end

  # Every refund email job for the payment, in whatever state.
  defp refund_emails(payment), do: Repo.aggregate(email_jobs(payment), :count)

  defp complete_emails(payment),
    do: Repo.update_all(email_jobs(payment), set: [state: "completed"])

  defp email_jobs(payment) do
    from(j in Oban.Job,
      where:
        j.worker == "Tymeslot.Workers.SendBookingPaymentRefunded" and
          fragment("?->>'booking_payment_id'", j.args) == ^payment.id
    )
  end

  defp record_refunded(payment) do
    payment
    |> Changeset.change(status: "refunded", refunded_amount_cents: payment.amount_cents)
    |> Repo.update!()
  end
end
