defmodule Tymeslot.Integrations.Calendar.PrimaryTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Security.Encryption

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    %{user: user}
  end

  defp insert_subscription(user) do
    insert(:calendar_integration,
      user: user,
      provider: "ics_url",
      base_url: "https://feeds.example.com",
      username_encrypted: nil,
      password_encrypted: nil,
      subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
    )
  end

  describe "the subscription-never-primary invariant" do
    test "toggling a subscription-only account off and on leaves the primary unset", %{
      user: user
    } do
      subscription = insert_subscription(user)

      assert {:ok, toggled_off} =
               CalendarManagement.toggle_with_primary_rebalance(subscription)

      refute toggled_off.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil

      assert {:ok, toggled_on} =
               CalendarManagement.toggle_with_primary_rebalance(toggled_off)

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
               CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, toggled} = CalendarManagement.toggle_with_primary_rebalance(primary)
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
               CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, toggled} = CalendarManagement.toggle_with_primary_rebalance(primary)
      refute toggled.is_active

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil
    end

    test "delete_with_primary_handling promotes the writable integration over a subscription",
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
               CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, _result} = CalendarPrimary.delete_with_primary_handling(primary)

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == fallback.id
    end

    test "delete_with_primary_handling clears the primary when only a subscription remains",
         %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true}]
        )

      _subscription = insert_subscription(user)

      assert {:ok, _result} =
               CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, _result} = CalendarPrimary.delete_with_primary_handling(primary)

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
             CalendarPrimary.set_primary_calendar_integration(user.id, integration.id)

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

    assert {:ok, _result} = CalendarPrimary.set_primary_calendar_integration(user.id, second.id)

    {:ok, cleared_first} = CalendarIntegrationQueries.get_for_user(first.id, user.id)
    assert cleared_first.default_booking_calendar_id == "old-default"
  end

  test "delete_with_primary_handling promotes another integration", %{user: user} do
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

    assert {:ok, _result} = CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

    assert {:ok, _result} = CalendarPrimary.delete_with_primary_handling(primary)

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

    assert {:ok, _result} = CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

    assert {:ok, toggled_primary} =
             CalendarManagement.toggle_with_primary_rebalance(primary)

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

    assert {:ok, _result} = CalendarPrimary.set_primary_calendar_integration(user.id, only.id)

    assert {:ok, toggled} = CalendarManagement.toggle_with_primary_rebalance(only)
    refute toggled.is_active

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == nil
  end

  describe "auto_select_primary_calendar/2" do
    test "CalDAV provider: writes calendar_paths from selected calendars alongside calendar_list",
         %{user: user} do
      path = "/dav/user@example.org/Calendar/"

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: [],
          calendar_list: []
        )

      calendars = [
        %{"id" => path, "path" => path, "name" => "Personal", "selected" => true}
      ]

      assert {:ok, updated} = CalendarPrimary.auto_select_primary_calendar(integration, calendars)

      assert updated.calendar_paths == [path]
      assert length(updated.calendar_list) == 1
    end

    test "OAuth (Google) provider: does NOT write calendar IDs into calendar_paths", %{
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_paths: [],
          calendar_list: []
        )

      # Atom-keyed maps as returned by GoogleProvider.format_calendar/1 —
      # they have no :path key, only :id.
      calendars = [
        %{id: "primary", name: "Primary", selected: true, primary: true}
      ]

      assert {:ok, updated} = CalendarPrimary.auto_select_primary_calendar(integration, calendars)

      assert updated.calendar_paths == []
      assert length(updated.calendar_list) == 1
    end

    test "skips a read-only calendar that is both first and provider-primary, in favour of the one writable entry",
         %{user: user} do
      # Delegated/Workspace resource accounts can have no `primary: true`
      # entry at all, so both the primary and selected tiers fall through
      # to `first_id_from_list/1`. If that first entry is a read-only
      # subscribed/shared calendar, the raw ladder would persist an
      # unwritable `default_booking_calendar_id`; the eligibility filter
      # must skip it in favour of the one writable calendar further down
      # the list.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_paths: [],
          calendar_list: []
        )

      calendars = [
        %{id: "holidays", name: "Holidays", selected: false, primary: false, read_only: true},
        %{id: "writable", name: "Writable", selected: false, primary: false, read_only: false}
      ]

      assert {:ok, updated} = CalendarPrimary.auto_select_primary_calendar(integration, calendars)

      assert updated.default_booking_calendar_id == "writable"
    end
  end
end
