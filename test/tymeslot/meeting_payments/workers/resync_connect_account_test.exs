defmodule Tymeslot.MeetingPayments.Workers.ResyncConnectAccountTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.Workers.ResyncConnectAccount
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  defp insert_active_account(stripe_account_id) do
    user = insert(:user)
    {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

    {:ok, account} =
      ConnectAccountQueries.update(account, %{
        stripe_account_id: stripe_account_id,
        status: :active,
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false
      })

    {user, account}
  end

  describe "perform/1" do
    test "retrieves the Stripe account and applies the event" do
      {user, _account} = insert_active_account("acct_GO")

      StripeStub.expect(
        :retrieve_account,
        StripeFixtures.object("account", %{
          "id" => "acct_GO",
          "created" => DateTime.to_unix(DateTime.utc_now()),
          "charges_enabled" => true,
          "payouts_enabled" => true,
          "details_submitted" => true,
          "requirements" => %{"disabled_reason" => nil}
        })
      )

      assert :ok =
               perform_job(ResyncConnectAccount, %{"stripe_account_id" => "acct_GO"})

      assert [%{path: "/v1/account", headers: headers}] = StripeStub.requests(:retrieve_account)
      assert headers["stripe-account"] == "acct_GO"

      reloaded = ConnectAccountQueries.live_for_user(user.id)
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
      assert reloaded.details_submitted == true
    end

    test "discards when stripe_account_id is missing from args" do
      assert {:discard, "missing stripe_account_id"} =
               perform_job(ResyncConnectAccount, %{})
    end

    test "errors when Stripe rejects the request" do
      _ctx = insert_active_account("acct_BOOM")

      StripeStub.stub(:retrieve_account, {:error_fixture, "api_error"})

      assert {:error, %StripeError{type: "api_error"}} =
               perform_job(ResyncConnectAccount, %{"stripe_account_id" => "acct_BOOM"})
    end

    test "applies the snapshot even when the account's created matches the stored event time" do
      # Regression: the worker must stamp the snapshot with the current time,
      # not the account object's `created` (the constant account-creation time).
      # Here the stored last_account_event_at equals that account-creation time;
      # keying ordering off the object `created` would treat the resync as a
      # stale `:eq` and silently drop the capability change.
      account_created = 1_600_000_000

      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _account} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_RESTAMP",
          status: :active,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false,
          last_account_event_at: DateTime.from_unix!(account_created)
        })

      StripeStub.expect(
        :retrieve_account,
        StripeFixtures.object("account", %{
          "id" => "acct_RESTAMP",
          "created" => account_created,
          "charges_enabled" => true,
          "payouts_enabled" => true,
          "details_submitted" => true,
          "requirements" => %{"disabled_reason" => nil}
        })
      )

      assert :ok = perform_job(ResyncConnectAccount, %{"stripe_account_id" => "acct_RESTAMP"})

      reloaded = ConnectAccountQueries.live_for_user(user.id)
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
    end
  end
end
