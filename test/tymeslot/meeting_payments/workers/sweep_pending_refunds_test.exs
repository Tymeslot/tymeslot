defmodule Tymeslot.MeetingPayments.Workers.SweepPendingRefundsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.MeetingPayments.Workers.SweepPendingRefunds

  setup do
    %{payment: insert(:paid_booking_payment)}
  end

  defp recorded_minutes_ago(payment, minutes, attrs \\ []) do
    inserted_at = DateTime.add(DateTime.utc_now(:second), -minutes * 60, :second)
    insert(:booking_payment_refund, [booking_payment: payment, inserted_at: inserted_at] ++ attrs)
  end

  test "gives a refund pending past the grace period without a job a new one",
       %{payment: payment} do
    stranded = recorded_minutes_ago(payment, 11)

    assert :ok = perform_job(SweepPendingRefunds, %{})

    assert [%{args: %{"refund_id" => id}}] = all_enqueued(worker: ExecuteRefund)
    assert id == stranded.id
  end

  test "leaves a refund inside the grace period, and settled ones, alone", %{payment: payment} do
    recorded_minutes_ago(payment, 9)
    recorded_minutes_ago(payment, 60, status: :succeeded, stripe_refund_id: "re_DONE")
    recorded_minutes_ago(payment, 60, status: :failed, failure_code: "refund_failed")

    assert :ok = perform_job(SweepPendingRefunds, %{})

    assert all_enqueued(worker: ExecuteRefund) == []
  end

  test "adds no second job to a refund whose job is still waiting", %{payment: payment} do
    {:ok, refund} = Refunds.request_refund(payment, 1_000, :host, [])
    Repo.update_all(refund_query(refund.id), set: [inserted_at: ~U[2026-01-01 00:00:00Z]])

    assert :ok = perform_job(SweepPendingRefunds, %{})

    assert [%{args: %{"refund_id" => id}}] = all_enqueued(worker: ExecuteRefund)
    assert id == refund.id
  end

  defp refund_query(id), do: from(r in RefundSchema, where: r.id == ^id)
end
