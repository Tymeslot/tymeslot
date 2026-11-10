defmodule Tymeslot.MeetingPayments.ConnectAccountsTest do
  # `start_onboarding/1` reads the global meeting-payments flag and the Connect
  # client ID, which these tests change.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.StripeConnectTestHelpers

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountRetirement
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount

  setup :verify_on_exit!

  describe "start_onboarding/1" do
    setup :enable_meeting_payments

    test "start sends the host to Stripe's authorise page with no account created" do
      user = insert(:user)

      # No adapter expectation: verify_on_exit! fails the test on any call.
      assert {:ok, %{url: url, account: account}} = ConnectAccounts.start_onboarding(user)

      assert URI.parse(url).host == "connect.stripe.com"
      assert account.user_id == user.id

      row = ConnectAccountQueries.live_for_user(user.id)
      assert byte_size(row.oauth_nonce) == 43
      assert row.stripe_account_id == nil
      assert row.country == nil
      assert row.status == :creating
    end

    test "start is refused without a client ID" do
      with_config(:tymeslot, stripe_connect_client_id: nil)
      user = insert(:user)

      assert {:error, :oauth_not_configured} = ConnectAccounts.start_onboarding(user)
      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "is refused with the feature-access reason when meeting payments are disabled" do
      with_config(:tymeslot, meeting_payments_enabled: false)
      user = insert(:user)

      assert {:error, :feature_disabled} = ConnectAccounts.start_onboarding(user)
      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "start replaces an unfinished legacy account" do
      user = insert(:user)
      legacy = insert(:connect_account, user: user, stripe_account_id: "acct_CH")

      assert {:ok, %{url: url, account: account}} = ConnectAccounts.start_onboarding(user)

      assert URI.parse(url).host == "connect.stripe.com"
      assert account.id == legacy.id
      assert byte_size(ConnectAccountQueries.live_for_user(user.id).oauth_nonce) == 43
    end

    test "start is refused once an account is finished" do
      user = insert(:user)
      insert(:connect_account, user: user, details_submitted: true)

      assert {:error, :already_connected} = ConnectAccounts.start_onboarding(user)
      assert ConnectAccountQueries.live_for_user(user.id).oauth_nonce == nil
    end

    test "start is refused for an account already connected through OAuth" do
      user = insert(:user)

      insert(:connect_account,
        user: user,
        details_submitted: false,
        oauth_connected_at: DateTime.utc_now(:second)
      )

      assert {:error, :already_connected} = ConnectAccounts.start_onboarding(user)
      assert ConnectAccountQueries.live_for_user(user.id).oauth_nonce == nil
    end

    test "start after a disconnect begins on a new row" do
      user = insert(:user)
      old = insert(:connect_account, user: user, stripe_account_id: "acct_DEAD")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      assert {:ok, %{account: account}} = ConnectAccounts.start_onboarding(user)

      refute account.id == old.id
      assert account.stripe_account_id == nil
    end
  end

  describe "complete_oauth_callback/3" do
    setup :enable_meeting_payments

    test "a completed callback connects the account Stripe names, in its own country" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_fr", "acct_FR")

      expect_retrieve("acct_FR", %{
        "country" => "FR",
        "default_currency" => "eur",
        "charges_enabled" => true
      })

      assert {:ok, account} = ConnectAccounts.complete_oauth_callback(user, "code_fr", state)

      assert account.stripe_account_id == "acct_FR"
      assert account.country == "FR"
      assert account.default_currency == "eur"
      assert account.charges_enabled
      assert %DateTime{} = account.oauth_connected_at
      assert account.oauth_nonce == nil
      assert account.status == :active
    end

    test "replaying a callback does not exchange the code twice" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_once", "acct_FR")
      expect_retrieve("acct_FR", %{"country" => "FR", "default_currency" => "eur"})

      assert {:ok, _account} = ConnectAccounts.complete_oauth_callback(user, "code_once", state)

      assert {:error, :state_already_used} =
               ConnectAccounts.complete_oauth_callback(user, "code_once", state)
    end

    test "two simultaneous callbacks exchange once" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_race", "acct_FR")
      expect_retrieve("acct_FR", %{"country" => "FR", "default_currency" => "eur"})

      results =
        [1, 2]
        |> Enum.map(fn _n ->
          Task.async(fn -> ConnectAccounts.complete_oauth_callback(user, "code_race", state) end)
        end)
        |> Task.await_many()

      assert [{:error, :state_already_used}] = Enum.reject(results, &match?({:ok, _account}, &1))
      assert [{:ok, _account}] = Enum.filter(results, &match?({:ok, _account}, &1))
    end

    test "a state issued to another host is refused before any exchange" do
      user = insert(:user)
      other = insert(:user)
      state = started_state(other)

      assert {:error, :user_mismatch} =
               ConnectAccounts.complete_oauth_callback(user, "code", state)

      assert byte_size(ConnectAccountQueries.live_for_user(other.id).oauth_nonce) == 43
    end

    test "a tampered state is refused before any exchange" do
      user = insert(:user)
      state = started_state(user)

      assert {:error, :invalid_state} =
               ConnectAccounts.complete_oauth_callback(user, "code", state <> "x")
    end

    test "a callback is refused by the feature gate before the state is spent" do
      user = insert(:user)
      state = started_state(user)
      with_config(:tymeslot, meeting_payments_enabled: false)

      assert {:error, :feature_disabled} =
               ConnectAccounts.complete_oauth_callback(user, "code", state)

      assert byte_size(ConnectAccountQueries.live_for_user(user.id).oauth_nonce) == 43
    end

    test "a refused code leaves the row unconnected" do
      user = insert(:user)
      state = started_state(user)

      expect(StripeAdapterMock, :exchange_oauth_code, fn "code_bad" ->
        {:error, :invalid_grant}
      end)

      assert {:error, :invalid_grant} =
               ConnectAccounts.complete_oauth_callback(user, "code_bad", state)

      assert ConnectAccountQueries.live_for_user(user.id).stripe_account_id == nil
    end

    test "a callback replaces a stuck legacy account" do
      user = insert(:user)

      legacy =
        insert(:connect_account,
          user: user,
          stripe_account_id: "acct_CH",
          country: "ch",
          default_currency: "chf",
          charges_enabled: true,
          payouts_enabled: true,
          disabled_reason: "requirements.past_due",
          # In the future, so an event guard left armed would drop the snapshot.
          last_account_event_at: DateTime.add(DateTime.utc_now(:second), 1, :day)
        )

      state = started_state(user)
      expect_exchange("code_fr", "acct_FR")
      expect_retrieve("acct_FR", %{"country" => "FR", "default_currency" => "eur"})

      assert {:ok, account} = ConnectAccounts.complete_oauth_callback(user, "code_fr", state)

      assert account.id == legacy.id
      assert account.stripe_account_id == "acct_FR"
      assert account.country == "FR"
      assert account.default_currency == "eur"
      refute account.charges_enabled
      refute account.payouts_enabled
      assert account.disabled_reason == nil
      assert DateTime.compare(account.last_account_event_at, legacy.last_account_event_at) == :lt
    end

    test "choosing a legacy account again records it as an OAuth connection" do
      user = insert(:user)
      insert(:connect_account, user: user, stripe_account_id: "acct_CH")
      state = started_state(user)
      expect_exchange("code_ch", "acct_CH")
      expect_retrieve("acct_CH", %{"country" => "CH", "default_currency" => "chf"})

      assert {:ok, account} = ConnectAccounts.complete_oauth_callback(user, "code_ch", state)

      assert account.stripe_account_id == "acct_CH"
      assert %DateTime{} = account.oauth_connected_at
      refute_enqueued(worker: DeauthorizeConnectAccount)
    end

    test "an account linked to another host is refused and left connected" do
      user = insert(:user)
      insert(:connect_account, stripe_account_id: "acct_X")
      state = started_state(user)
      expect_exchange("code_x", "acct_X")

      assert {:error, :account_already_linked} =
               ConnectAccounts.complete_oauth_callback(user, "code_x", state)

      assert ConnectAccountQueries.live_for_user(user.id).stripe_account_id == nil
      refute_enqueued(worker: DeauthorizeConnectAccount)
    end

    test "an account linked elsewhere while the callback ran is refused and left connected" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_x", "acct_RACE")

      expect(StripeAdapterMock, :retrieve_account, fn "acct_RACE" ->
        insert(:connect_account, stripe_account_id: "acct_RACE")
        {:ok, snapshot("acct_RACE", %{"country" => "FR", "default_currency" => "eur"})}
      end)

      assert {:error, :account_already_linked} =
               ConnectAccounts.complete_oauth_callback(user, "code_x", state)

      refute_enqueued(worker: DeauthorizeConnectAccount)
    end

    test "an unsupported currency is refused and the connection revoked" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_jp", "acct_JP")
      expect_retrieve("acct_JP", %{"country" => "JP", "default_currency" => "jpy"})

      assert {:error, :unsupported_currency} =
               ConnectAccounts.complete_oauth_callback(user, "code_jp", state)

      assert ConnectAccountQueries.live_for_user(user.id).stripe_account_id == nil

      assert_enqueued(worker: DeauthorizeConnectAccount, args: %{stripe_account_id: "acct_JP"})

      expect(StripeAdapterMock, :deauthorize_account, fn "acct_JP" -> :ok end)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :payments)
    end

    test "an unsupported currency leaves an account the host already holds connected" do
      user = insert(:user)
      insert(:connect_account, user: user, stripe_account_id: "acct_CH", default_currency: "chf")
      state = started_state(user)
      expect_exchange("code_ch", "acct_CH")
      expect_retrieve("acct_CH", %{"country" => "JP", "default_currency" => "jpy"})

      assert {:error, :unsupported_currency} =
               ConnectAccounts.complete_oauth_callback(user, "code_ch", state)

      assert_enqueued(worker: DeauthorizeConnectAccount, args: %{stripe_account_id: "acct_CH"})

      # No `deauthorize_account` expectation: Mox fails the job on any call.
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :payments)

      row = ConnectAccountQueries.live_for_user(user.id)
      assert row.stripe_account_id == "acct_CH"
      assert row.default_currency == "chf"
      assert row.oauth_connected_at == nil
    end

    test "a host whose row disappears during the exchange keeps the connection" do
      user = insert(:user)
      state = started_state(user)
      old_row = ConnectAccountQueries.live_for_user(user.id)

      expect(StripeAdapterMock, :exchange_oauth_code, fn "code_fr" ->
        ConnectAccountQueries.soft_delete_for_user(user.id, DateTime.utc_now(:second))
        {:ok, %{stripe_user_id: "acct_FR"}}
      end)

      expect_retrieve("acct_FR", %{"country" => "FR", "default_currency" => "eur"})

      assert {:ok, _account} = ConnectAccounts.complete_oauth_callback(user, "code_fr", state)

      row = ConnectAccountQueries.live_for_user(user.id)
      refute row.id == old_row.id
      assert row.stripe_account_id == "acct_FR"
      assert %DateTime{} = row.oauth_connected_at
    end

    test "a failed read refuses, schedules revocation and can be retried" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_one", "acct_FR")
      expect(StripeAdapterMock, :retrieve_account, fn "acct_FR" -> {:error, :timeout} end)

      assert {:error, :oauth_failed} =
               ConnectAccounts.complete_oauth_callback(user, "code_one", state)

      assert ConnectAccountQueries.live_for_user(user.id).stripe_account_id == nil

      assert_enqueued(
        worker: DeauthorizeConnectAccount,
        args: %{stripe_account_id: "acct_FR"},
        scheduled_at: {DateTime.add(DateTime.utc_now(:second), 3600), delta: 60}
      )

      retry_state = started_state(user)
      expect_exchange("code_two", "acct_FR")
      expect_retrieve("acct_FR", %{"country" => "FR", "default_currency" => "eur"})

      assert {:ok, account} =
               ConnectAccounts.complete_oauth_callback(user, "code_two", retry_state)

      assert account.stripe_account_id == "acct_FR"

      # No `deauthorize_account` expectation: Mox fails the job on any call.
      assert %{success: 1, failure: 0} =
               Oban.drain_queue(queue: :payments, with_scheduled: true)
    end

    test "a snapshot with no currency is refused the same way" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_fr", "acct_FR")
      expect_retrieve("acct_FR", %{"country" => "FR"})

      assert {:error, :oauth_failed} =
               ConnectAccounts.complete_oauth_callback(user, "code_fr", state)

      assert ConnectAccountQueries.live_for_user(user.id).stripe_account_id == nil

      assert_enqueued(
        worker: DeauthorizeConnectAccount,
        args: %{stripe_account_id: "acct_FR"},
        scheduled_at: {DateTime.add(DateTime.utc_now(:second), 3600), delta: 60}
      )
    end

    test "a failed exchange can be retried" do
      user = insert(:user)
      state = started_state(user)

      expect(StripeAdapterMock, :exchange_oauth_code, fn "code_one" ->
        {:error, :oauth_failed}
      end)

      assert {:error, :oauth_failed} =
               ConnectAccounts.complete_oauth_callback(user, "code_one", state)

      retry_state = started_state(user)
      expect_exchange("code_two", "acct_FR")
      expect_retrieve("acct_FR", %{"country" => "FR", "default_currency" => "eur"})

      assert {:ok, account} =
               ConnectAccounts.complete_oauth_callback(user, "code_two", retry_state)

      assert account.stripe_account_id == "acct_FR"
    end

    test "an account event older than the connection is ignored" do
      user = insert(:user)
      state = started_state(user)
      expect_exchange("code_fr", "acct_FR")
      expect_retrieve("acct_FR", %{"country" => "FR", "default_currency" => "eur"})

      assert {:ok, connected} = ConnectAccounts.complete_oauth_callback(user, "code_fr", state)

      assert :ok =
               ConnectAccounts.apply_account_event(
                 snapshot("acct_FR", %{"charges_enabled" => true}),
                 DateTime.add(connected.last_account_event_at, -1, :hour)
               )

      refute ConnectAccountQueries.live_for_user(user.id).charges_enabled
    end
  end

  describe "preserved prices across a reconnect" do
    setup :enable_meeting_payments

    test "reconnecting a different-currency account keeps the host's charge currency for preserved prices" do
      user = insert(:user)
      insert(:profile, user: user)
      insert(:meeting_type, user: user, payment_required: true, price_cents: 5000)
      insert(:connect_account, user: user, stripe_account_id: "acct_EU", default_currency: "eur")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      connect_gbp_account(user)

      assert ConnectAccountQueries.live_for_user(user.id).default_currency == "eur"
      assert MeetingPayments.charge_currency(user.id) == "eur"
    end

    test "a host with no priced types takes the new account's currency" do
      user = insert(:user)
      insert(:profile, user: user)
      insert(:meeting_type, user: user, payment_required: false, price_cents: nil)
      insert(:connect_account, user: user, stripe_account_id: "acct_EU", default_currency: "eur")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      connect_gbp_account(user)

      assert ConnectAccountQueries.live_for_user(user.id).default_currency == "gbp"
    end

    test "a host with no recorded currency takes the new account's currency" do
      user = insert(:user)
      insert(:profile, user: user)
      insert(:meeting_type, user: user, payment_required: true, price_cents: 5000)

      connect_gbp_account(user)

      assert ConnectAccountQueries.live_for_user(user.id).default_currency == "gbp"
    end

    test "an unsupported legacy currency is not recorded as the charge currency" do
      user = insert(:user)
      insert(:profile, user: user)
      insert(:meeting_type, user: user, payment_required: true, price_cents: 5000)
      insert(:connect_account, user: user, stripe_account_id: "acct_JP", default_currency: "jpy")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      connect_gbp_account(user)

      assert ConnectAccountQueries.live_for_user(user.id).default_currency == "gbp"
    end
  end

  defp connect_gbp_account(user) do
    state = started_state(user)
    expect_exchange("code_gb", "acct_GB")

    expect_retrieve("acct_GB", %{
      "country" => "GB",
      "default_currency" => "gbp",
      "charges_enabled" => true
    })

    assert {:ok, _account} = ConnectAccounts.complete_oauth_callback(user, "code_gb", state)
  end
end
