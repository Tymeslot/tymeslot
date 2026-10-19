defmodule Tymeslot.Workers.SendChargeDisputeOpenedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.Workers.SendChargeDisputeOpened

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1, which is the CircuitBreaker GenServer, not the test
  # process. Pointing the adapter here collects the delivered email instead.
  # Safe because the module is `async: false`.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  defp insert_payment(attrs \\ %{}) do
    defaults = %{
      attendee_email: "alice@example.com",
      attendee_name: "Alice",
      host_email: "host@example.com",
      host_name: "Bob Host",
      meeting_type_name: "Discovery Call",
      amount_cents: 5000,
      currency: "eur",
      status: "disputed",
      stripe_charge_id: "ch_DISPUTED",
      stripe_account_id: "acct_TEST",
      paid_at: DateTime.utc_now(:second)
    }

    insert(:booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  describe "perform/1" do
    test "succeeds for a disputed booking with a host_email" do
      payment = insert_payment()

      assert :ok =
               perform_job(SendChargeDisputeOpened, %{
                 "booking_payment_id" => payment.id,
                 "reason" => "fraudulent"
               })
    end

    test "writes the delivered alert in the host's own language" do
      host = insert(:user, locale: "de")
      payment = insert_payment(%{host_user_id: host.id})

      assert :ok =
               perform_job(SendChargeDisputeOpened, %{
                 "booking_payment_id" => payment.id,
                 "reason" => "fraudulent"
               })

      assert_received {:email, email}
      assert email.to == [{"Bob Host", "host@example.com"}]
      assert email.subject == "Stripe-Zahlungsstreitigkeit eröffnet: €50.00"
      assert email.text_body =~ "Hallo Bob Host,"
      refute email.text_body =~ "WHAT HAPPENS NEXT"
    end

    test "discards when booking_payment is missing" do
      assert {:discard, "booking_payment not found"} =
               perform_job(SendChargeDisputeOpened, %{
                 "booking_payment_id" => UUID.generate()
               })
    end

    test "discards when booking_payment_id is missing from args" do
      assert {:discard, "missing booking_payment_id"} =
               perform_job(SendChargeDisputeOpened, %{})
    end
  end

  describe "uniqueness" do
    test "second Oban.insert for the same booking_payment_id within 24 h is a conflict" do
      payment = insert_payment()
      args = %{"booking_payment_id" => payment.id, "reason" => "fraudulent"}

      assert {:ok, %{conflict?: false}} = Oban.insert(SendChargeDisputeOpened.new(args))
      assert {:ok, %{conflict?: true}} = Oban.insert(SendChargeDisputeOpened.new(args))
    end
  end
end
