defmodule Tymeslot.Integrations.Calendar.PrimaryTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Primary
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Security.Encryption

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    %{user: user}
  end

  defp insert_subscription(user, attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: user,
          provider: "ics_url",
          base_url: "https://feeds.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
        ],
        attrs
      )
    )
  end

  defp insert_exchange(user, attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: user,
          provider: "exchange",
          base_url: "https://exchange.example.com/EWS/Exchange.asmx"
        ],
        attrs
      )
    )
  end

  # The attrs an OAuth callback hands `insert_integration/1` once it has
  # resolved its calendars.
  defp caldav_attrs(user, name) do
    %{
      user_id: user.id,
      name: name,
      provider: "caldav",
      base_url: "https://dav.example.com",
      username: name,
      password: "secret",
      provider_account_id: "https://dav.example.com||#{name}",
      calendar_paths: ["/dav/#{name}"],
      is_active: true
    }
  end

  defp stored_primary_id(user) do
    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    profile.primary_calendar_integration_id
  end

  describe "a new integration and the primary" do
    test "the first bookable integration becomes the primary", %{user: user} do
      assert {:ok, created} = Management.insert_integration(caldav_attrs(user, "first"))

      assert stored_primary_id(user) == created.id
    end

    test "a second integration leaves an active primary alone", %{user: user} do
      {:ok, first} = Management.insert_integration(caldav_attrs(user, "first"))
      {:ok, _second} = Management.insert_integration(caldav_attrs(user, "second"))

      assert stored_primary_id(user) == first.id
    end

    test "replaces a primary that is paused", %{user: user} do
      paused = insert(:calendar_integration, user: user, provider: "caldav", is_active: false)
      {:ok, _profile} = ProfileQueries.set_primary_calendar_integration(user.id, paused.id)

      {:ok, created} = Management.insert_integration(caldav_attrs(user, "fresh"))

      assert stored_primary_id(user) == created.id
    end

    test "a calendar waiting to be reconnected is not made the primary", %{user: user} do
      flagged =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          needs_reauth: true
        )

      {:ok, _active} = Management.toggle_with_primary_rebalance(flagged)

      assert stored_primary_id(user) == nil
    end

    test "a subscription never becomes the primary", %{user: user} do
      subscription = insert_subscription(user, is_active: false)

      {:ok, _active} = Management.toggle_with_primary_rebalance(subscription)

      assert stored_primary_id(user) == nil
    end
  end

  describe "switching a calendar on or off" do
    test "flips the stored state, not the state of a copy read earlier", %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "caldav", is_active: true)

      assert {:ok, _toggled} =
               Management.toggle_with_primary_rebalance(%{integration | is_active: false})

      refute Repo.reload!(integration).is_active
    end

    test "answers not found for a calendar deleted since it was read", %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "caldav")
      Repo.delete!(integration)

      assert {:error, :not_found} = Management.toggle_with_primary_rebalance(integration)
    end
  end

  describe "reconnecting through the provider's sign-in" do
    test "reactivates a paused calendar and makes it the primary when there is none",
         %{user: user} do
      paused =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: "acct-1",
          is_active: false
        )

      assert {:ok, reconnected} =
               Management.reconnect_integration(paused, %{
                 access_token: "fresh",
                 is_active: true
               })

      assert reconnected.is_active
      assert stored_primary_id(user) == paused.id
    end

    test "refuses to reactivate a calendar whose account another active one uses",
         %{user: user} do
      _active =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: "acct-1"
        )

      paused =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: "acct-1",
          is_active: false
        )

      assert {:error, :duplicate_account} =
               Management.reconnect_integration(paused, %{
                 access_token: "fresh",
                 is_active: true
               })

      refute Repo.reload!(paused).is_active
    end
  end

  describe "pausing a calendar" do
    test "pauses the primary read before it was switched back on, and hands the role on",
         %{user: user} do
      other = insert(:calendar_integration, user: user, provider: "caldav")

      primary =
        insert(:calendar_integration, user: user, provider: "caldav", is_active: true)

      {:ok, _profile} = ProfileQueries.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, _paused} =
               Management.pause_integration(%{primary | is_active: false})

      refute Repo.reload!(primary).is_active
      assert stored_primary_id(user) == other.id
    end
  end

  describe "an Exchange mailbox as primary" do
    # This block pinned the opposite until the EWS write path landed: an
    # Exchange mailbox was read-only, so it was refused as a primary and
    # skipped by every promotion. It can now receive a booking, so it is an
    # ordinary candidate, and these are the same five situations read the
    # other way. The invariant itself has not gone anywhere; the subscription
    # block below is where it still holds.
    test "set_primary_calendar_integration accepts an Exchange mailbox", %{user: user} do
      exchange = insert_exchange(user)

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, exchange.id)

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == exchange.id
    end

    test "deleting the primary promotes the most recent candidate, Exchange included",
         %{user: user} do
      # Promotion takes the most recently added candidate, and the Exchange
      # mailbox is the newest of the three. Nothing filters it out any more, so
      # recency alone decides.
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}],
          inserted_at: ~N[2024-01-01 10:00:00]
        )

      _older_fallback =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: ["/dav/fallback"],
          inserted_at: ~N[2024-01-02 10:00:00]
        )

      exchange = insert_exchange(user, inserted_at: ~N[2024-01-03 10:00:00])

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, _result} = Deletion.delete_with_primary_reassignment(user.id, primary.id)

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == exchange.id
    end

    test "deactivating the primary promotes the most recent candidate, Exchange included",
         %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}],
          inserted_at: ~N[2024-01-01 10:00:00]
        )

      _older_fallback =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: ["/dav/fallback"],
          inserted_at: ~N[2024-01-02 10:00:00]
        )

      exchange = insert_exchange(user, inserted_at: ~N[2024-01-03 10:00:00])

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, toggled} = Management.toggle_with_primary_rebalance(primary)
      refute toggled.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == exchange.id
    end

    test "deactivating a primary with only an Exchange mailbox remaining promotes it",
         %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}]
        )

      exchange = insert_exchange(user)

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, toggled} = Management.toggle_with_primary_rebalance(primary)
      refute toggled.is_active

      # The user is left with a primary that works, where before they were
      # left with none at all.
      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == exchange.id
    end

    test "activating an Exchange mailbox adopts it as the primary", %{user: user} do
      exchange = insert_exchange(user)

      assert {:ok, toggled_off} = Management.toggle_with_primary_rebalance(exchange)
      refute toggled_off.is_active

      assert {:ok, toggled_on} = Management.toggle_with_primary_rebalance(toggled_off)
      assert toggled_on.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == exchange.id
    end
  end

  describe "the subscription-never-primary invariant" do
    test "toggling a subscription-only account off and on leaves the primary unset", %{
      user: user
    } do
      subscription = insert_subscription(user)

      assert {:ok, toggled_off} =
               Management.toggle_with_primary_rebalance(subscription)

      refute toggled_off.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil

      assert {:ok, toggled_on} =
               Management.toggle_with_primary_rebalance(toggled_off)

      assert toggled_on.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil
    end

    test "deactivating a writable primary promotes the remaining writable integration over a subscription",
         %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}]
        )

      fallback =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: ["/dav/fallback"]
        )

      _subscription = insert_subscription(user)

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, toggled} = Management.toggle_with_primary_rebalance(primary)
      refute toggled.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == fallback.id
    end

    test "deactivating a writable primary with only a subscription remaining clears the primary",
         %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}]
        )

      _subscription = insert_subscription(user)

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, toggled} = Management.toggle_with_primary_rebalance(primary)
      refute toggled.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil
    end

    test "deleting the primary promotes the writable integration over a subscription",
         %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}]
        )

      fallback =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: ["/dav/fallback"]
        )

      _subscription = insert_subscription(user)

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, _result} = Deletion.delete_with_primary_reassignment(user.id, primary.id)

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == fallback.id
    end

    test "deleting the primary clears the primary when only a subscription remains",
         %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}]
        )

      _subscription = insert_subscription(user)

      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, _result} = Deletion.delete_with_primary_reassignment(user.id, primary.id)

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil
    end
  end

  test "set_primary_calendar_integration sets default booking calendar from list", %{user: user} do
    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        calendar_list: [
          %{"id" => "work", "selected" => true, "primary" => true, "path" => "/cal/work"}
        ]
      )

    assert {:ok, updated} =
             Primary.set_primary_calendar_integration(user.id, integration.id)

    assert updated.default_booking_calendar_id == "work"

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == updated.id
  end

  test "set_primary NO LONGER clears other booking calendars", %{user: user} do
    first =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        default_booking_calendar_id: "old-default"
      )

    second =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        calendar_list: [%{"id" => "primary", "selected" => true, "path" => "/cal/primary"}]
      )

    assert {:ok, _result} = Primary.set_primary_calendar_integration(user.id, second.id)

    {:ok, cleared_first} = CalendarIntegrationQueries.get_for_user(first.id, user.id)
    assert cleared_first.default_booking_calendar_id == "old-default"
  end

  test "deleting the primary promotes another integration", %{user: user} do
    primary =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        calendar_list: [%{"id" => "primary", "selected" => true, "path" => "/cal/primary"}]
      )

    fallback =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        calendar_paths: ["/dav/fallback"]
      )

    assert {:ok, _result} = Primary.set_primary_calendar_integration(user.id, primary.id)

    assert {:ok, _result} = Deletion.delete_with_primary_reassignment(user.id, primary.id)

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == fallback.id
  end

  test "toggle_with_primary_rebalance reassigns primary when toggling current primary off", %{
    user: user
  } do
    primary =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        calendar_list: [%{"id" => "primary", "selected" => true}]
      )

    other =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        calendar_paths: ["/dav/fallback"]
      )

    assert {:ok, _result} = Primary.set_primary_calendar_integration(user.id, primary.id)

    assert {:ok, toggled_primary} =
             Management.toggle_with_primary_rebalance(primary)

    refute toggled_primary.is_active

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == other.id
  end

  test "toggle_with_primary_rebalance clears primary when no other active integrations", %{
    user: user
  } do
    only =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        calendar_list: [%{"id" => "primary", "selected" => true}]
      )

    assert {:ok, _result} = Primary.set_primary_calendar_integration(user.id, only.id)

    assert {:ok, toggled} = Management.toggle_with_primary_rebalance(only)
    refute toggled.is_active

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == nil
  end

  # A primary whose credentials do not decrypt for now (a rotated key, say)
  # is still the calendar the user chose; turning another calendar on must
  # not quietly demote it.
  test "activating a calendar keeps an unreadable but active primary", %{user: user} do
    unreadable =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        username_encrypted: :crypto.strong_rand_bytes(40),
        password_encrypted: :crypto.strong_rand_bytes(40)
      )

    {:ok, _profile} = ProfileQueries.set_primary_calendar_integration(user.id, unreadable.id)

    assert {:error, :requires_reencryption, _stale} =
             CalendarIntegrationQueries.get(unreadable.id)

    other = insert(:calendar_integration, user: user, provider: "google", is_active: false)

    assert {:ok, %{is_active: true}} = Management.toggle_with_primary_rebalance(other)

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == unreadable.id
  end

  test "activating a calendar adopts it when the primary is paused", %{user: user} do
    paused = insert(:calendar_integration, user: user, provider: "google", is_active: false)
    {:ok, _profile} = ProfileQueries.set_primary_calendar_integration(user.id, paused.id)
    other = insert(:calendar_integration, user: user, provider: "caldav", is_active: false)

    assert {:ok, %{is_active: true}} = Management.toggle_with_primary_rebalance(other)

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == other.id
  end

  test "set_primary_calendar_integration refuses a paused integration", %{user: user} do
    paused = insert(:calendar_integration, user: user, is_active: false)

    assert {:error, :inactive} =
             Primary.set_primary_calendar_integration(user.id, paused.id)
  end

  test "toggling the primary off never promotes a calendar waiting to be reconnected", %{
    user: user
  } do
    primary = insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-01 10:00:00])

    _flagged =
      insert(:calendar_integration,
        user: user,
        needs_reauth: true,
        inserted_at: ~N[2024-01-02 10:00:00]
      )

    assert {:ok, _result} = Primary.set_primary_calendar_integration(user.id, primary.id)
    assert {:ok, _toggled} = Management.toggle_with_primary_rebalance(primary)

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == nil
  end
end
