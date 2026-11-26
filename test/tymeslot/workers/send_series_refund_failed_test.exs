defmodule Tymeslot.Workers.SendSeriesRefundFailedTest do
  @moduledoc """
  A series refund failure email job queued before the upgrade, in its old
  args, still tells the host the refund was not made.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.Workers.SendSeriesRefundFailed

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1; pointing it here collects the delivered email.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    series = insert(:booking_series)

    payment =
      insert(:paid_booking_payment,
        meeting_id: nil,
        series_id: series.id,
        attendee_email: "ada@example.com",
        attendee_name: "Ada Lovelace",
        host_email: "host@example.com",
        host_name: "Grace Host",
        meeting_type_name: "Mentoring",
        amount_cents: 20_000,
        currency: "eur"
      )

    %{payment: payment}
  end

  # The args a job carried when it was queued.
  defp queued_args(booking_payment_id) do
    %{
      "booking_payment_id" => booking_payment_id,
      "amount_cents" => 10_000,
      "refunded_before_cents" => 0,
      "reason" => "under_dispute"
    }
  end

  test "tells the host the series refund was not made", %{payment: payment} do
    assert :ok = perform_job(SendSeriesRefundFailed, queued_args(payment.id))

    assert_received {:email, email}
    assert email.to == [{"Grace Host", "host@example.com"}]
    assert email.subject == "Refund of €100.00 to Ada Lovelace not made"
    assert email.text_body =~ "You cancelled sessions of a series"
    assert email.text_body =~ "The sessions stay cancelled."
  end

  test "sends nothing once the payment is gone" do
    assert {:discard, "booking_payment not found"} =
             perform_job(SendSeriesRefundFailed, queued_args(UUID.generate()))

    refute_received {:email, _email}
  end
end
