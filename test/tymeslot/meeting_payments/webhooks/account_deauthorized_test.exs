defmodule Tymeslot.MeetingPayments.Webhooks.AccountDeauthorizedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.AccountDeauthorized
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Profiles

  setup :verify_on_exit!

  @connected_at ~U[2026-11-01 10:00:00Z]

  # The event as Stripe sends it: `data.object` is the platform's
  # application, and the connected account is the top-level `account`.
  defp event(account_id, created \\ ~U[2026-11-05 10:00:00Z]) do
    base = %{
      "id" => "evt_deauth",
      "type" => "account.application.deauthorized",
      "created" => DateTime.to_unix(created),
      "data" => %{
        "object" => %{"id" => "ca_PLATFORM", "object" => "application", "name" => "Tymeslot"}
      }
    }

    if account_id, do: Map.put(base, "account", account_id), else: base
  end

  defp connected_host(attrs \\ []) do
    user = insert(:user)
    insert(:profile, user: user)

    account =
      insert(
        :connect_account,
        Keyword.merge(
          [
            user: user,
            default_currency: "eur",
            charges_enabled: true,
            oauth_connected_at: @connected_at
          ],
          attrs
        )
      )

    {user, account}
  end

  test "a host removing Tymeslot at Stripe disconnects the account" do
    {user, account} = connected_host()
    meeting = insert(:meeting, status: :awaiting_payment, organizer_user_id: user.id)

    payment =
      insert(:booking_payment,
        host_user_id: user.id,
        meeting: meeting,
        stripe_checkout_session_id: "cs_held",
        status: :pending
      )

    # `expire_stripe_session` rescues a Mox error, so only a message to the
    # test process can show that the call was never made.
    test_pid = self()

    stub(StripeAdapterMock, :expire_checkout_session, fn id, _opts ->
      send(test_pid, {:expired_at_stripe, id})
      {:ok, %{}}
    end)

    Phoenix.PubSub.subscribe(Tymeslot.PubSub, HeldMeetings.topic(meeting.id))

    assert :ok = AccountDeauthorized.handle(event(account.stripe_account_id))

    refute ConnectAccountQueries.live_for_user(user.id)
    assert BookingPaymentQueries.get(payment.id).status == :failed
    assert {:ok, %{status: :expired}} = MeetingQueries.get_meeting(meeting.id)
    refute_received {:expired_at_stripe, _id}
    assert_receive :expired
    refute_enqueued(worker: DeauthorizeConnectAccount)
  end

  test "a replayed event is harmless" do
    {user, account} = connected_host()
    event = event(account.stripe_account_id)

    assert :ok = AccountDeauthorized.handle(event)
    assert :ok = AccountDeauthorized.handle(event)

    refute ConnectAccountQueries.live_for_user(user.id)
  end

  test "an event from before a reconnect is ignored" do
    {user, account} = connected_host()
    before_reconnect = DateTime.add(@connected_at, -60, :second)

    assert :ok =
             AccountDeauthorized.handle(event(account.stripe_account_id, before_reconnect))

    assert ConnectAccountQueries.live_for_user(user.id)
  end

  test "an event for an unknown account is ignored" do
    assert :ok = AccountDeauthorized.handle(event("acct_NOBODY"))
  end

  test "an event with no account is rejected permanently" do
    assert {:error, :permanent, :invalid_event} = AccountDeauthorized.handle(event(nil))
  end

  test "an event with no creation time is rejected permanently" do
    {_user, account} = connected_host()
    event = account.stripe_account_id |> event() |> Map.delete("created")

    assert {:error, :permanent, :invalid_event} = AccountDeauthorized.handle(event)
    assert ConnectAccountQueries.by_stripe_account_id(account.stripe_account_id)
  end

  test "a legacy account with no OAuth connection is retired" do
    {user, account} = connected_host(oauth_connected_at: nil)

    assert :ok = AccountDeauthorized.handle(event(account.stripe_account_id))

    refute ConnectAccountQueries.live_for_user(user.id)
  end

  test "an event at the very second of the connection applies" do
    {user, account} = connected_host()

    assert :ok = AccountDeauthorized.handle(event(account.stripe_account_id, @connected_at))

    refute ConnectAccountQueries.live_for_user(user.id)
  end

  describe "events of the other mode" do
    test "a test-mode event on live keys leaves the account and its bookings alone" do
      with_config(:stripity_stripe, api_key: "sk_live_platform")
      {user, account} = connected_host()
      payment = insert(:booking_payment, host_user_id: user.id, status: :pending)

      event = account.stripe_account_id |> event() |> Map.put("livemode", false)

      assert :ok = AccountDeauthorized.handle(event)

      assert ConnectAccountQueries.live_for_user(user.id)
      assert BookingPaymentQueries.get(payment.id).status == :pending
    end

    test "a test-mode event on test keys applies" do
      with_config(:stripity_stripe, api_key: "sk_test_platform")
      {user, account} = connected_host()

      event = account.stripe_account_id |> event() |> Map.put("livemode", false)

      assert :ok = AccountDeauthorized.handle(event)

      refute ConnectAccountQueries.live_for_user(user.id)
    end
  end

  test "removing Tymeslot at Stripe keeps the charge currency for a reconnect" do
    {user, account} = connected_host(default_currency: "eur")

    assert :ok = AccountDeauthorized.handle(event(account.stripe_account_id))

    assert Profiles.last_charge_currency(user.id) == "eur"
  end
end
