defmodule Tymeslot.MeetingPayments.Workers.BackfillChargeTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments

  import ExUnit.CaptureLog

  alias Ecto.UUID
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.Workers.BackfillCharge
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  @account "acct_BACKFILL"

  defp paid_payment(attrs \\ []) do
    insert(
      :booking_payment,
      Keyword.merge(
        [
          status: :paid,
          stripe_account_id: @account,
          stripe_payment_intent_id: "pi_BACKFILL",
          stripe_charge_id: nil
        ],
        attrs
      )
    )
  end

  defp args(payment),
    do: %{"booking_payment_id" => payment.id, "payment_intent_id" => "pi_BACKFILL"}

  defp intent(latest_charge),
    do:
      StripeFixtures.object("payment_intent_with_latest_charge", %{
        "id" => "pi_BACKFILL",
        "latest_charge" => latest_charge
      })

  describe "perform/1" do
    test "records the charge id when Stripe has it" do
      payment = paid_payment()
      StripeStub.stub(:retrieve_payment_intent, intent(%{"id" => "ch_new"}))

      assert :ok = perform_job(BackfillCharge, args(payment))

      assert Repo.reload!(payment).stripe_charge_id == "ch_new"

      assert [%{path: "/v1/payment_intents/pi_BACKFILL", headers: headers, query: query}] =
               StripeStub.requests(:retrieve_payment_intent)

      assert headers["stripe-account"] == @account
      assert query["expand"] == ["latest_charge"]
    end

    test "a payment that already has a charge id makes no Stripe call" do
      payment = paid_payment(stripe_charge_id: "ch_KNOWN")

      assert :ok = perform_job(BackfillCharge, args(payment))

      assert StripeStub.requests() == []
      assert Repo.reload!(payment).stripe_charge_id == "ch_KNOWN"
    end

    test "a payment that no longer exists is discarded" do
      assert {:discard, :not_found} =
               perform_job(BackfillCharge, %{
                 "booking_payment_id" => UUID.generate(),
                 "payment_intent_id" => "pi_GONE"
               })

      assert StripeStub.requests() == []
    end

    test "an intent without a charge yet is retried" do
      payment = paid_payment()
      StripeStub.stub(:retrieve_payment_intent, intent(nil))

      assert {:error, :charge_not_available} = perform_job(BackfillCharge, args(payment))
      assert Repo.reload!(payment).stripe_charge_id == nil
    end

    test "a missing intent at Stripe cancels" do
      payment = paid_payment()
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "resource_missing"})

      log =
        capture_log(fn ->
          assert {:cancel, %StripeError{code: "resource_missing"}} =
                   perform_job(BackfillCharge, args(payment))
        end)

      assert log =~ "refused by Stripe"
    end

    test "a charge id the row refuses cancels the job" do
      insert(:booking_payment, stripe_charge_id: "ch_TAKEN")
      payment = paid_payment()
      StripeStub.stub(:retrieve_payment_intent, intent(%{"id" => "ch_TAKEN"}))

      log =
        capture_log(fn ->
          assert {:cancel, %Ecto.Changeset{}} = perform_job(BackfillCharge, args(payment))
        end)

      assert log =~ "could not store the charge id"
      assert Repo.reload!(payment).stripe_charge_id == nil
    end

    test "a timeout is retried" do
      payment = paid_payment()
      StripeStub.stub(:retrieve_payment_intent, {:transport_error, :timeout})

      assert {:error, %StripeError{type: "api_connection_error"}} =
               perform_job(BackfillCharge, args(payment))
    end

    test "the last attempt that fails is logged as an error" do
      payment = paid_payment()
      StripeStub.stub(:retrieve_payment_intent, intent(nil))

      log =
        capture_log(fn ->
          assert {:error, :charge_not_available} =
                   perform_job(BackfillCharge, args(payment), attempt: 12)
        end)

      assert log =~ "[error]"
      assert log =~ "Charge id backfill gave up"
    end
  end

  describe "enqueue/2" do
    test "inserts one job per payment however often it is asked" do
      payment = paid_payment()

      assert :ok = BackfillCharge.enqueue(payment, "pi_BACKFILL")
      assert :ok = BackfillCharge.enqueue(payment, "pi_BACKFILL")

      assert [%{args: %{"booking_payment_id" => id, "payment_intent_id" => "pi_BACKFILL"}}] =
               all_enqueued(worker: BackfillCharge)

      assert id == payment.id
    end
  end
end
