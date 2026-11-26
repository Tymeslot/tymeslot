defmodule Tymeslot.MeetingPayments.Workers.SeriesHostRefundTest do
  @moduledoc """
  A series refund job queued before the refund outbox: it records the
  refund for the host under the key its earlier attempts may have used, so
  a refund one of them made at Stripe is replayed rather than made twice,
  and tells the host when it gives the refund up.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.MeetingPayments.Workers.SeriesHostRefund
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.SendSeriesRefundFailed

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1; pointing it here collects the delivered email.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
  end

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

  test "a refund no retry can make discards the job and tells the host",
       %{host: host, payment: payment} do
    assert {:discard, :invalid_amount} =
             payment |> queued_job(host.id, 6000) |> SeriesHostRefund.perform()

    stale = DateTime.add(DateTime.utc_now(:second), -61, :day)
    payment |> Changeset.change(paid_at: stale) |> Repo.update!()

    assert {:discard, :outside_refund_window} =
             payment |> queued_job(host.id, 1000) |> SeriesHostRefund.perform()

    assert refunds(payment) == []
    assert [%{"amount_cents" => 1000}, %{"amount_cents" => 6000}] = host_emails(payment)
  end

  test "the host's email says the series refund was not made", %{host: host, payment: payment} do
    payment |> Changeset.change(status: :disputed) |> Repo.update!()

    assert {:discard, :under_dispute} =
             payment |> queued_job(host.id, 3000) |> SeriesHostRefund.perform()

    assert [args] = host_emails(payment)
    assert :ok = perform_job(SendSeriesRefundFailed, args)

    assert_received {:email, email}
    assert [{_name, address}] = email.to
    assert address == payment.host_email
    assert email.text_body =~ "You cancelled sessions of a series"
  end

  test "a payment another host took is not refunded, and nobody is told", %{payment: payment} do
    assert {:discard, :not_found} =
             payment |> queued_job(payment.host_user_id + 1, 1000) |> SeriesHostRefund.perform()

    assert refunds(payment) == []
    assert host_emails(payment) == []
  end

  test "a payment refunded already tells the host nothing", %{host: host, payment: payment} do
    payment
    |> Changeset.change(status: :refunded, refunded_amount_cents: payment.amount_cents)
    |> Repo.update!()

    assert {:discard, :already_refunded} =
             payment |> queued_job(host.id, 1000) |> SeriesHostRefund.perform()

    assert host_emails(payment) == []
  end

  describe "while another refund of the payment is pending" do
    setup %{payment: payment} do
      {:ok, _pending} = Refunds.request_refund(payment, 3000, :host, [])
      :ok
    end

    test "the refund is retried, the host not yet told", %{host: host, payment: payment} do
      job = queued_job(payment, host.id, 3000)

      assert {:error, :refund_in_progress} = SeriesHostRefund.perform(%{job | attempt: 1})

      assert [%{source: :host}] = refunds(payment)
      assert host_emails(payment) == []
    end

    test "the last attempt still refused tells the host", %{host: host, payment: payment} do
      job = queued_job(payment, host.id, 3000)

      assert {:error, :refund_in_progress} =
               SeriesHostRefund.perform(%{job | attempt: job.max_attempts})

      assert [%{"amount_cents" => 3000}] = host_emails(payment)
    end

    test "a retry once that refund settled records this one", %{host: host, payment: payment} do
      job = queued_job(payment, host.id, 3000)
      assert {:error, :refund_in_progress} = SeriesHostRefund.perform(%{job | attempt: 1})

      Repo.update_all(from(r in RefundSchema, where: r.booking_payment_id == ^payment.id),
        set: [status: :failed, failure_code: "card_declined"]
      )

      assert :ok = SeriesHostRefund.perform(%{job | attempt: 2})
      assert [%{source: :series_host, status: :pending}] = pending_refunds(payment)
    end
  end

  # The args of every series refund failure email queued for the payment,
  # smallest amount first.
  defp host_emails(payment) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "Tymeslot.Workers.SendSeriesRefundFailed" and
            fragment("?->>'booking_payment_id'", j.args) == ^payment.id,
        order_by: fragment("(?->>'amount_cents')::int", j.args),
        select: j.args
      )
    )
  end

  defp pending_refunds(payment),
    do: payment |> refunds() |> Enum.filter(&(&1.status == :pending))
end
