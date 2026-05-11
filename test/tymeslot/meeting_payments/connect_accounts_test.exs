defmodule Tymeslot.MeetingPayments.ConnectAccountsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Workers.SendConnectAccountRestricted

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

    test "row stays in recoverable 'creating' state when create_account_link fails" do
      user = insert(:user)
      country = "ch"

      expect(StripeAdapterMock, :create_account, fn _params, _opts ->
        {:ok, %{id: "acct_FAIL_LINK", default_currency: "chf"}}
      end)

      expect(StripeAdapterMock, :create_account_link, fn _params ->
        {:error, %{message: "Stripe link creation failed"}}
      end)

      assert {:error, _reason} = ConnectAccounts.start_onboarding(user, country: country)

      # Row must still exist in "creating" state — not left in "active" with a
      # stripe_account_id set, since the link never succeeded.
      account = ConnectAccountQueries.live_for_user(user.id)
      assert account.status == "creating"
      assert is_nil(account.stripe_account_id)
    end
  end

  describe "disconnect/1" do
    test "soft-deletes the live account" do
      user = insert(:user)
      {:ok, _placeholder} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      assert {:ok, %{cancelled_count: 0}} = ConnectAccounts.disconnect(user)

      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "is a noop when no account exists" do
      user = insert(:user)
      assert {:ok, %{cancelled_count: 0}} = ConnectAccounts.disconnect(user)
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

    test "enqueues a restriction email when disabled_reason transitions from nil to a value" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_RESTRICT",
          status: "active",
          disabled_reason: nil
        })

      stripe_event = %{
        "id" => "acct_RESTRICT",
        "created" => DateTime.to_unix(DateTime.utc_now()),
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "requirements.past_due"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)

      reloaded = ConnectAccountQueries.live_for_user(user.id)

      assert_enqueued(
        worker: SendConnectAccountRestricted,
        args: %{
          connect_account_id: reloaded.id,
          user_id: user.id,
          stripe_account_id: "acct_RESTRICT",
          disabled_reason: "requirements.past_due"
        }
      )
    end

    test "does not enqueue a restriction email when disabled_reason is unchanged" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_SAME",
          status: "active",
          disabled_reason: "requirements.past_due"
        })

      stripe_event = %{
        "id" => "acct_SAME",
        "created" => DateTime.to_unix(DateTime.utc_now()),
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "requirements.past_due"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)

      refute_enqueued(worker: SendConnectAccountRestricted)
    end

    test "enqueues a restriction email when disabled_reason changes between two values" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_CHANGE",
          status: "active",
          disabled_reason: "requirements.past_due"
        })

      stripe_event = %{
        "id" => "acct_CHANGE",
        "created" => DateTime.to_unix(DateTime.utc_now()),
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "rejected.fraud"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)

      assert_enqueued(
        worker: SendConnectAccountRestricted,
        args: %{
          disabled_reason: "rejected.fraud",
          previous_disabled_reason: "requirements.past_due"
        }
      )
    end

    test "does not enqueue a restriction email when disabled_reason clears (non-nil → nil)" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_CLEAR",
          status: "active",
          disabled_reason: "requirements.past_due"
        })

      stripe_event = %{
        "id" => "acct_CLEAR",
        "created" => DateTime.to_unix(DateTime.utc_now()),
        "charges_enabled" => true,
        "payouts_enabled" => true,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)

      refute_enqueued(worker: SendConnectAccountRestricted)
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

    test "does not enqueue a duplicate job when the same event is delivered twice" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_REPLAY",
          status: "active",
          disabled_reason: nil
        })

      # Stripe replays carry the same `created` timestamp.
      timestamp = DateTime.to_unix(DateTime.utc_now(:second))

      event = %{
        "id" => "acct_REPLAY",
        "created" => timestamp,
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "requirements.past_due"}
      }

      assert :ok = ConnectAccounts.apply_account_event(event)
      # Second delivery with identical timestamp must be a no-op.
      assert :ok = ConnectAccounts.apply_account_event(event)

      assert [_single_job] =
               all_enqueued(
                 worker: SendConnectAccountRestricted,
                 args: %{stripe_account_id: "acct_REPLAY"}
               )
    end

    test "is a no-op for a stripe_account_id belonging to a soft-deleted account" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_DELETED",
          status: "active",
          charges_enabled: true
        })

      ConnectAccounts.disconnect(user)

      stripe_event = %{
        "id" => "acct_DELETED",
        "created" => DateTime.to_unix(DateTime.utc_now()),
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => false,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_event)
      # The deleted row must not have been updated.
      refute ConnectAccountQueries.live_for_user(user.id)
      refute_enqueued(worker: SendConnectAccountRestricted)
    end
  end
end
