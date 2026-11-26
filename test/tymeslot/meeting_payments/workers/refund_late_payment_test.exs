defmodule Tymeslot.MeetingPayments.Workers.RefundLatePaymentTest do
  @moduledoc """
  A late-payment refund job queued before the refund outbox: it records
  the refund under the key its earlier attempts may have used, so a refund
  one of them made at Stripe is replayed rather than made twice, and leaves
  the rest to `ExecuteRefund`, or raises an admin alert when its last
  attempt cannot record the refund either.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Ecto.UUID

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  setup :capture_admin_alerts

  setup do
    host = insert(:user)
    meeting = insert(:meeting, status: :expired, organizer_user_id: host.id)

    payment =
      insert(:paid_booking_payment,
        host_user_id: host.id,
        meeting: meeting,
        stripe_account_id: "acct_LATE"
      )

    %{host: host, payment: payment}
  end

  test "a RefundLatePayment job queued before the upgrade requests a refund under its old key",
       %{payment: payment} do
    queued_at = DateTime.add(DateTime.utc_now(), -600, :second)

    assert :ok = perform(payment, inserted_at: queued_at)
    assert StripeStub.requests() == []

    assert [%RefundSchema{source: :late_payment, amount_cents: 5000} = refund] = refunds(payment)
    assert refund.legacy_idempotency_key == "late_payment_refund:#{payment.id}:late:5000"
    assert DateTime.compare(refund.legacy_since, queued_at) == :eq

    StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LATE"))
    assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

    assert [%{form: form, headers: headers}] = StripeStub.requests(:create_refund)
    assert headers["idempotency-key"] == "late_payment_refund:#{payment.id}:late:5000"
    assert headers["stripe-account"] == "acct_LATE"
    assert form["amount"] == "5000"

    assert Repo.reload!(payment).status == :refunded
    assert refund_emails(payment) == 1
  end

  test "a job scheduled by a decided dispute keeps its own key", %{payment: payment} do
    payment
    |> Changeset.change(refunded_amount_cents: 3000, status: :partially_refunded)
    |> Repo.update!()

    assert :ok = perform(payment, reason: "after_dispute")

    assert [%{amount_cents: 2000, legacy_idempotency_key: key}] = refunds(payment)
    assert key == "late_payment_refund:#{payment.id}:after_dispute:2000"
  end

  test "a rerun of a job that recorded its refund records none", %{payment: payment} do
    {:ok, job} = Oban.insert(RefundLatePayment.new(%{booking_payment_id: payment.id}))
    # As Oban hands it to the worker: read back, string-keyed, dated.
    job = Repo.reload!(job)

    assert :ok = RefundLatePayment.perform(job)
    assert :ok = RefundLatePayment.perform(job)

    assert [_one] = refunds(payment)
  end

  test "a refusal is discarded at once and leaves the booking on the host's list",
       %{host: host, payment: payment} do
    stale = DateTime.add(DateTime.utc_now(:second), -61, :day)

    for {changes, reason} <- [
          {[status: :disputed], :under_dispute},
          {[paid_at: stale], :outside_refund_window},
          {[paid_at: nil], :not_paid}
        ] do
      payment |> Changeset.change(changes) |> Repo.update!()
      assert {:discard, ^reason} = perform(payment)

      payment
      |> Repo.reload!()
      |> Changeset.change(status: :paid, paid_at: payment.paid_at)
      |> Repo.update!()
    end

    assert refunds(payment) == []
    payment_id = payment.id
    assert [%{id: ^payment_id}] = BookingPayments.list_outstanding_refunds_for_host(host.id)
  end

  test "the discarded refusals are expected outcomes, not failures to record" do
    for reason <- [:not_paid, :outside_refund_window, :under_dispute, :invalid_amount] do
      assert RefundLatePayment.expected_outcome?(reason)
    end

    refute RefundLatePayment.expected_outcome?(:refund_in_progress)
  end

  # An earlier attempt's refund, made at Stripe while its own transaction
  # rolled back, was recorded by `charge.refunded`, which sends no email.
  test "emails the attendee when the refund was recorded by Stripe's webhook instead",
       %{payment: payment} do
    record_refunded(payment)

    assert :ok = perform(payment)

    assert refunds(payment) == []
    assert refund_emails(payment) == 1
  end

  test "sends no second email when the refund was already emailed", %{payment: payment} do
    record_refunded(payment)
    {:ok, _job} = Oban.insert(SendBookingPaymentRefunded.new(%{booking_payment_id: payment.id}))
    complete_emails(payment)

    assert :ok = perform(payment)

    assert refund_emails(payment) == 1
  end

  # A job built by hand without the time it was queued gives its refund a
  # legacy key with no date, which the refund's changeset refuses: the
  # insert raises, as a fault in the database would.
  describe "an attempt that cannot record the refund" do
    test "is retried without an alert", %{payment: payment} do
      assert {:error, %Ecto.InvalidChangesetError{}} = undated_job(payment, 9)

      assert refunds(payment) == []
      refute_received {:send_alert, _type, _payload}
    end

    test "raises an alert on the job's last attempt", %{payment: payment} do
      assert {:error, %Ecto.InvalidChangesetError{}} = undated_job(payment, 10)

      payment_id = payment.id

      assert_received {:send_alert, :late_payment_refund_failed,
                       %{booking_payment_id: ^payment_id, reason_code: _code}}
    end
  end

  test "a payment that is gone is discarded" do
    assert {:discard, :not_found} =
             perform_job(RefundLatePayment, %{booking_payment_id: UUID.generate()})
  end

  defp perform(payment, opts \\ []) do
    args =
      case Keyword.get(opts, :reason) do
        nil -> %{booking_payment_id: payment.id}
        reason -> %{booking_payment_id: payment.id, reason: reason}
      end

    perform_job(RefundLatePayment, args,
      attempt: 1,
      max_attempts: 10,
      inserted_at: Keyword.get(opts, :inserted_at, DateTime.utc_now())
    )
  end

  defp undated_job(payment, attempt) do
    RefundLatePayment.perform(%Oban.Job{
      args: %{"booking_payment_id" => payment.id},
      attempt: attempt,
      max_attempts: 10
    })
  end

  defp refunds(payment),
    do: Repo.all(from(r in RefundSchema, where: r.booking_payment_id == ^payment.id))

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
    |> Changeset.change(status: :refunded, refunded_amount_cents: payment.amount_cents)
    |> Repo.update!()
  end
end
