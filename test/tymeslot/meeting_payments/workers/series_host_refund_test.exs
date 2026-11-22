defmodule Tymeslot.MeetingPayments.Workers.SeriesHostRefundTest do
  @moduledoc """
  A series refund job queued before the refund outbox: it records the
  refund for the host under the key its earlier attempts may have used, so
  a refund one of them made at Stripe is replayed rather than made twice.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.MeetingPayments.Workers.SeriesHostRefund
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses

  setup do
    host = insert(:user)

    payment =
      insert(:paid_booking_payment, host_user_id: host.id, stripe_account_id: "acct_SERIES")

    %{host: host, payment: payment}
  end

  # The job as it was queued before the upgrade, read back as Oban
  # hands it to the worker.
  defp queued_job(payment, host_user_id, amount_cents) do
    {:ok, job} =
      %{
        booking_payment_id: payment.id,
        host_user_id: host_user_id,
        amount_cents: amount_cents,
        refunded_before_cents: payment.refunded_amount_cents
      }
      |> SeriesHostRefund.new()
      |> Oban.insert()

    Repo.reload!(job)
  end

  defp refunds(payment),
    do: Repo.all(from(r in RefundSchema, where: r.booking_payment_id == ^payment.id))

  test "a SeriesHostRefund job queued before the upgrade requests a refund under its old key",
       %{host: host, payment: payment} do
    job = queued_job(payment, host.id, 3000)

    assert :ok = SeriesHostRefund.perform(job)
    assert StripeStub.requests() == []

    host_id = host.id

    assert [
             %RefundSchema{
               source: :series_host,
               amount_cents: 3000,
               requested_by_user_id: ^host_id
             } = refund
           ] = refunds(payment)

    assert refund.legacy_idempotency_key == "series_refund:#{job.id}"
    assert DateTime.compare(refund.legacy_since, job.inserted_at) == :eq

    StripeStub.expect(:create_refund, StripeStubResponses.refund("re_SERIES_OLD"))
    assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id})

    assert [%{form: %{"amount" => "3000"}, headers: headers}] =
             StripeStub.requests(:create_refund)

    assert headers["idempotency-key"] == "series_refund:#{job.id}"
    assert %{refunded_amount_cents: 3000, status: :partially_refunded} = Repo.reload!(payment)
  end

  test "a rerun of a job that recorded its refund records none", %{host: host, payment: payment} do
    job = queued_job(payment, host.id, 3000)

    assert :ok = SeriesHostRefund.perform(job)
    assert :ok = SeriesHostRefund.perform(job)

    assert [_one] = refunds(payment)
  end

  test "a refund no retry can make discards the job", %{host: host, payment: payment} do
    assert {:discard, :invalid_amount} =
             payment |> queued_job(host.id, 6000) |> SeriesHostRefund.perform()

    stale = DateTime.add(DateTime.utc_now(:second), -61, :day)
    payment |> Changeset.change(paid_at: stale) |> Repo.update!()

    assert {:discard, :outside_refund_window} =
             payment |> queued_job(host.id, 1000) |> SeriesHostRefund.perform()

    assert refunds(payment) == []
  end

  test "a payment another host took is not refunded", %{payment: payment} do
    assert {:discard, :not_found} =
             payment |> queued_job(payment.host_user_id + 1, 1000) |> SeriesHostRefund.perform()

    assert refunds(payment) == []
  end
end
