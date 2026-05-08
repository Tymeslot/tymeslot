defmodule Tymeslot.MeetingPayments.ConnectAccountsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  setup :verify_on_exit!

  describe "start_onboarding/2" do
    test "creates Stripe account, persists row, returns AccountLink URL" do
      user = insert(:user)
      country = "ch"

      expect(StripeAdapterMock, :create_account, fn params, opts ->
        assert params.type == "standard"
        assert params.country == country
        assert opts[:idempotency_key] == "account:#{user.id}"
        {:ok, %{id: "acct_TEST_123", default_currency: "chf"}}
      end)

      expect(StripeAdapterMock, :create_account_link, fn params ->
        assert params.account == "acct_TEST_123"
        assert params.type == "account_onboarding"
        {:ok, %{url: "https://connect.stripe.com/setup/acct_TEST"}}
      end)

      assert {:ok, %{url: url}} = ConnectAccounts.start_onboarding(user, country: country)
      assert url =~ "connect.stripe.com"

      account = ConnectAccountQueries.live_for_user(user.id)
      assert account.stripe_account_id == "acct_TEST_123"
      assert account.default_currency == "chf"
      assert account.status == "active"
    end

    test "resumes onboarding when placeholder exists from a prior crashed attempt" do
      user = insert(:user)
      {:ok, _placeholder} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      expect(StripeAdapterMock, :create_account, fn _params, opts ->
        assert opts[:idempotency_key] == "account:#{user.id}"
        {:ok, %{id: "acct_RESUMED", default_currency: "chf"}}
      end)

      expect(StripeAdapterMock, :create_account_link, fn _params ->
        {:ok, %{url: "https://connect.stripe.com/resume"}}
      end)

      assert {:ok, %{url: _url}} = ConnectAccounts.start_onboarding(user, country: "ch")

      account = ConnectAccountQueries.live_for_user(user.id)
      assert account.stripe_account_id == "acct_RESUMED"
    end
  end

  describe "disconnect/1" do
    test "soft-deletes the live account" do
      user = insert(:user)
      {:ok, _placeholder} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      :ok = ConnectAccounts.disconnect(user)

      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "is a noop when no account exists" do
      user = insert(:user)
      assert :ok = ConnectAccounts.disconnect(user)
    end
  end

  describe "apply_account_event/1" do
    test "updates capability flags from a Stripe account event" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_EVENT",
          status: "active"
        })

      stripe_event = %{
        "id" => "acct_EVENT",
        "created" => DateTime.to_unix(DateTime.utc_now()),
        "charges_enabled" => true,
        "payouts_enabled" => true,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)

      reloaded = ConnectAccountQueries.live_for_user(user.id)
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
      assert reloaded.details_submitted == true
    end

    test "ignores events for unknown accounts" do
      stripe_event = %{
        "id" => "acct_UNKNOWN",
        "created" => DateTime.to_unix(DateTime.utc_now()),
        "charges_enabled" => true,
        "payouts_enabled" => true,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)
    end

    test "ignores out-of-order older events" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      now = DateTime.utc_now(:second)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_OOO",
          status: "active",
          charges_enabled: true,
          last_account_event_at: now
        })

      older = DateTime.add(now, -3600, :second)

      stripe_event = %{
        "id" => "acct_OOO",
        "created" => DateTime.to_unix(older),
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => false,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)

      reloaded = ConnectAccountQueries.live_for_user(user.id)
      assert reloaded.charges_enabled == true
    end
  end
end
