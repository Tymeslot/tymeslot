defmodule Tymeslot.Workers.SendRefundFailedTest do
  @moduledoc """
  The host's email when a refund they decided failed for good: who it goes
  to, what it says for a single booking and for a series, and in which
  language.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Workers.SendRefundFailed

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1; pointing it here collects the delivered email.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    payment =
      insert(:paid_booking_payment,
        attendee_email: "ada@example.com",
        attendee_name: "Ada Lovelace",
        host_email: "host@example.com",
        host_name: "Grace Host",
        meeting_type_name: "Mentoring",
        amount_cents: 20_000,
        currency: "eur"
      )

    refund =
      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 10_000,
        source: :cancellation,
        status: :failed,
        failure_code: "charge_disputed",
        settled_at: DateTime.utc_now(:second)
      )

    %{payment: payment, refund: refund}
  end

  defp run(refund) do
    %{changes: %{args: args}} = SendRefundFailed.new_for(refund)
    perform_job(SendRefundFailed, args)
  end

  test "tells the host Stripe did not make the refund, naming the attendee and amount",
       %{refund: refund} do
    assert :ok = run(refund)

    assert_received {:email, email}
    assert email.to == [{"Grace Host", "host@example.com"}]
    assert email.subject == "Refund of €100.00 to Ada Lovelace not made"

    assert email.text_body =~
             "Stripe declined or could not complete the refund of €100.00 to Ada Lovelace for their booking."

    assert email.text_body =~ "Check the payment in your Stripe dashboard."
    assert email.text_body =~ "/dashboard/payments"
  end

  test "a series cancellation's refund says its sessions stay cancelled", %{
    payment: payment,
    refund: refund
  } do
    series = insert(:booking_series)
    payment |> Changeset.change(meeting_id: nil, series_id: series.id) |> Repo.update!()
    refund = refund |> Changeset.change(source: :series_host) |> Repo.update!()

    assert :ok = run(refund)

    assert_received {:email, email}
    assert email.text_body =~ "You cancelled sessions of a series"
    assert email.text_body =~ "The sessions stay cancelled."
  end

  # Refunded from the payments page, nothing was cancelled with it.
  test "a refund the host made of a series payment says nothing was cancelled", %{
    payment: payment,
    refund: refund
  } do
    series = insert(:booking_series)
    payment |> Changeset.change(meeting_id: nil, series_id: series.id) |> Repo.update!()
    refund = refund |> Changeset.change(source: :host) |> Repo.update!()

    assert :ok = run(refund)

    assert_received {:email, email}

    assert email.text_body =~
             "Stripe declined or could not complete the refund of €100.00 to Ada Lovelace for their booking."

    refute email.text_body =~ "cancelled"
  end

  test "is written in the host's own language", %{payment: payment, refund: refund} do
    host = insert(:user, locale: "de")
    payment |> Changeset.change(host_user_id: host.id) |> Repo.update!()

    assert :ok = run(refund)

    assert_received {:email, email}
    refute email.subject =~ "not made"
    assert email.text_body =~ "Hallo Grace Host,"
  end

  test "one email per refund", %{refund: refund} do
    assert {:ok, first} = Oban.insert(SendRefundFailed.new_for(refund))
    assert {:ok, second} = Oban.insert(SendRefundFailed.new_for(refund))

    assert second.conflict?
    assert second.id == first.id
  end

  # Stripe reported the refund made after it was failed, before the email went.
  test "sends nothing for a refund no longer failed", %{refund: refund} do
    refund
    |> Changeset.change(status: :succeeded, failure_code: nil, stripe_refund_id: "re_LATE")
    |> Repo.update!()

    assert {:cancel, "refund no longer failed"} = run(refund)
    refute_received {:email, _email}
  end

  test "sends nothing once the refund is gone" do
    assert {:discard, "refund not found"} =
             perform_job(SendRefundFailed, %{refund_id: UUID.generate()})

    refute_received {:email, _email}
  end
end
