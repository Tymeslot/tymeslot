defmodule Tymeslot.Workers.SendSeriesRefundFailedTest do
  @moduledoc """
  The host's email when the refund of a cancelled series could not be
  made: who it goes to, what it says, and in which language.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Workers.SendSeriesRefundFailed

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1; pointing it here collects the delivered email.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    payment =
      insert(:booking_payment,
        attendee_email: "ada@example.com",
        attendee_name: "Ada Lovelace",
        host_email: "host@example.com",
        host_name: "Grace Host",
        meeting_type_name: "Mentoring",
        amount_cents: 20_000,
        currency: "eur",
        status: :paid,
        stripe_account_id: "acct_TEST",
        paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day)
      )

    %{payment: payment}
  end

  defp run(payment, reason) do
    %{changes: %{args: args}} = SendSeriesRefundFailed.new_for(payment.id, 10_000, 0, reason)
    perform_job(SendSeriesRefundFailed, args)
  end

  test "tells the host the refund was not made, and why", %{payment: payment} do
    assert :ok = run(payment, :outside_refund_window)

    assert_received {:email, email}
    assert email.to == [{"Grace Host", "host@example.com"}]
    assert email.subject == "Series refund not made: €100.00"
    assert email.text_body =~ "the refund of €100.00 to the attendee could not be made"
    assert email.text_body =~ "older than the 60-day refund window"
    assert email.text_body =~ "Ada Lovelace"
    assert email.text_body =~ "/dashboard/payments"
  end

  test "a refund Stripe kept refusing says so", %{payment: payment} do
    assert :ok = run(payment, :api_error)

    assert_received {:email, email}
    assert email.text_body =~ "Stripe did not accept the refund after several attempts."
  end

  test "is written in the host's own language", %{payment: payment} do
    host = insert(:user, locale: "de")
    payment |> Changeset.change(host_user_id: host.id) |> Repo.update!()

    assert :ok = run(payment, :under_dispute)

    assert_received {:email, email}
    refute email.subject =~ "Series refund not made"
    assert email.text_body =~ "Hallo Grace Host,"
  end

  test "sends nothing once the payment is gone" do
    %{changes: %{args: args}} =
      SendSeriesRefundFailed.new_for(UUID.generate(), 10_000, 0, :under_dispute)

    assert {:discard, "booking_payment not found"} = perform_job(SendSeriesRefundFailed, args)
    refute_received {:email, _email}
  end
end
