defmodule Tymeslot.MeetingPayments.ConnectAccountsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
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

    test "does not overwrite a payment that was concurrently transitioned to paid" do
      # Regression for the TOCTOU race: list_pending_for_host runs outside the
      # transaction and snapshots the payment as "pending". Before the transaction
      # executes, a concurrent checkout.session.completed webhook flips the same
      # row to "paid". The conditional UPDATE (status = 'pending') must skip that
      # row so the paid status is preserved and cancelled_count stays accurate.
      user = insert(:user)
      {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      payment =
        insert(:booking_payment,
          host_user_id: user.id,
          stripe_checkout_session_id: "cs_race_test",
          status: "pending"
        )

      # Simulate the concurrent webhook arriving: flip the row to "paid" directly.
      {:ok, _updated} = BookingPaymentQueries.update(payment, %{status: "paid"})

      # disconnect/1 pre-fetches the payment as "pending" (it was pending when
      # list_pending_for_host ran), but inside the transaction the conditional
      # UPDATE finds status = 'paid' and must not overwrite it.
      stub(StripeAdapterMock, :expire_checkout_session, fn _session_id, _opts ->
        {:error, %{message: "already paid"}}
      end)

      assert {:ok, %{cancelled_count: 0}} = ConnectAccounts.disconnect(user)

      # The payment row must still be "paid" — not "failed".
      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == "paid"
    end
  end

  describe "apply_account_event/2" do
    test "updates capability flags from a Stripe account event" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_EVENT",
          status: "active"
        })

      stripe_account = %{
        "id" => "acct_EVENT",
        "charges_enabled" => true,
        "payouts_enabled" => true,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))

      reloaded = ConnectAccountQueries.live_for_user(user.id)
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
      assert reloaded.details_submitted == true
    end

    test "ignores events for unknown accounts" do
      stripe_account = %{
        "id" => "acct_UNKNOWN",
        "charges_enabled" => true,
        "payouts_enabled" => true,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))
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

      stripe_account = %{
        "id" => "acct_RESTRICT",
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "requirements.past_due"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))

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

    test "does not enqueue a restriction email while onboarding is still unsubmitted" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_UNSUBMITTED",
          status: "active",
          disabled_reason: nil
        })

      # Stripe stamps a brand-new account with past_due before the host finishes
      # onboarding — that is not a restriction the host should be emailed about.
      stripe_account = %{
        "id" => "acct_UNSUBMITTED",
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => false,
        "requirements" => %{"disabled_reason" => "requirements.past_due"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))

      refute_enqueued(worker: SendConnectAccountRestricted)
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

      stripe_account = %{
        "id" => "acct_SAME",
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "requirements.past_due"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))

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

      stripe_account = %{
        "id" => "acct_CHANGE",
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "rejected.fraud"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))

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

      stripe_account = %{
        "id" => "acct_CLEAR",
        "charges_enabled" => true,
        "payouts_enabled" => true,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))

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

      stripe_account = %{
        "id" => "acct_OOO",
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => false,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, older)

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

      # Stripe replays carry the same envelope `created` timestamp.
      event_at = DateTime.utc_now(:second)

      stripe_account = %{
        "id" => "acct_REPLAY",
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => "requirements.past_due"}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, event_at)
      # Second delivery with identical timestamp must be a no-op.
      assert :ok = ConnectAccounts.apply_account_event(stripe_account, event_at)

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

      stripe_account = %{
        "id" => "acct_DELETED",
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => false,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert :ok = ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))
      # The deleted row must not have been updated.
      refute ConnectAccountQueries.live_for_user(user.id)
      refute_enqueued(worker: SendConnectAccountRestricted)
    end
  end
end
