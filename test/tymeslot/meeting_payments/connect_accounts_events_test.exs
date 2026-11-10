defmodule Tymeslot.MeetingPayments.ConnectAccountsEventsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.Workers.SendConnectAccountRestricted

  describe "apply_account_event/2" do
    test "updates capability flags from a Stripe account event" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_EVENT",
          status: :active
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

    test "returns the rejected changeset and leaves the row unchanged when the update fails" do
      user = insert(:user)
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_REJECTED",
          status: :active
        })

      stripe_account = %{
        "id" => "acct_REJECTED",
        "charges_enabled" => "not-a-boolean",
        "payouts_enabled" => true,
        "details_submitted" => true,
        "requirements" => %{"disabled_reason" => nil}
      }

      assert {:error, %Ecto.Changeset{errors: errors}} =
               ConnectAccounts.apply_account_event(stripe_account, DateTime.utc_now(:second))

      assert Keyword.has_key?(errors, :charges_enabled)

      reloaded = ConnectAccountQueries.live_for_user(user.id)
      refute reloaded.payouts_enabled
      assert reloaded.last_account_event_at == nil
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_RESTRICT",
          status: :active,
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_UNSUBMITTED",
          status: :active,
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_SAME",
          status: :active,
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_CHANGE",
          status: :active,
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_CLEAR",
          status: :active,
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      now = DateTime.utc_now(:second)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_OOO",
          status: :active,
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_REPLAY",
          status: :active,
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
      {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id)

      {:ok, _updated} =
        ConnectAccountQueries.update(account, %{
          stripe_account_id: "acct_DELETED",
          status: :active,
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
