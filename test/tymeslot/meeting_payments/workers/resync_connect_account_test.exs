defmodule Tymeslot.MeetingPayments.Workers.ResyncConnectAccountTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Mox

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.ResyncConnectAccount

  setup :verify_on_exit!
  setup :set_mox_from_context

  defp insert_active_account(stripe_account_id \\ "acct_RESYNC") do
    user = insert(:user)
    {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

    {:ok, account} =
      ConnectAccountQueries.update(account, %{
        stripe_account_id: stripe_account_id,
        status: "active",
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false
      })

    {user, account}
  end

  describe "perform/1" do
    test "retrieves the Stripe account and applies the event" do
      {user, _account} = insert_active_account("acct_GO")

      expect(StripeAdapterMock, :retrieve_account, fn "acct_GO" ->
        {:ok,
         %{
           "id" => "acct_GO",
           "created" => DateTime.to_unix(DateTime.utc_now()),
           "charges_enabled" => true,
           "payouts_enabled" => true,
           "details_submitted" => true,
           "requirements" => %{"disabled_reason" => nil}
         }}
      end)

      assert :ok =
               perform_job(ResyncConnectAccount, %{"stripe_account_id" => "acct_GO"})

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

      expect(StripeAdapterMock, :retrieve_account, fn "acct_BOOM" ->
        {:error, %{message: "boom"}}
      end)

      assert {:error, _reason} =
               perform_job(ResyncConnectAccount, %{"stripe_account_id" => "acct_BOOM"})
    end

    test "account without created field gets epoch fallback so real events stay accepted" do
      {user, _account} = insert_active_account("acct_NO_TS")

      # First resync: Stripe returns account data with no `created` field.
      # The worker must synthesise epoch 0, not wall-clock time.
      expect(StripeAdapterMock, :retrieve_account, fn "acct_NO_TS" ->
        {:ok,
         %{
           "id" => "acct_NO_TS",
           # `created` deliberately absent
           "charges_enabled" => false,
           "payouts_enabled" => false,
           "details_submitted" => false,
           "requirements" => %{"disabled_reason" => nil}
         }}
      end)

      assert :ok = perform_job(ResyncConnectAccount, %{"stripe_account_id" => "acct_NO_TS"})

      # A subsequent resync with a real (older-than-now) timestamp must still
      # be applied — epoch 0 must not block it.
      real_ts = System.os_time(:second) - 3600

      expect(StripeAdapterMock, :retrieve_account, fn "acct_NO_TS" ->
        {:ok,
         %{
           "id" => "acct_NO_TS",
           "created" => real_ts,
           "charges_enabled" => true,
           "payouts_enabled" => true,
           "details_submitted" => true,
           "requirements" => %{"disabled_reason" => nil}
         }}
      end)

      assert :ok = perform_job(ResyncConnectAccount, %{"stripe_account_id" => "acct_NO_TS"})

      reloaded = ConnectAccountQueries.live_for_user(user.id)
      assert reloaded.charges_enabled == true
    end
  end
end
