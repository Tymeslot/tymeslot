defmodule Tymeslot.Integrations.Calendar.PrimaryTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    %{user: user}
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

  test "set_primary clears other booking calendars", %{user: user} do
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

    assert {:ok, _} = CalendarPrimary.set_primary_calendar_integration(user.id, second.id)

    {:ok, cleared_first} = CalendarIntegrationQueries.get_for_user(first.id, user.id)
    assert cleared_first.default_booking_calendar_id == nil
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

    assert {:ok, _} = CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

    assert {:ok, _} = CalendarPrimary.delete_with_primary_handling(primary)

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

    assert {:ok, _} = CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

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

    assert {:ok, _} = CalendarPrimary.set_primary_calendar_integration(user.id, only.id)

    assert {:ok, toggled} = CalendarManagement.toggle_with_primary_rebalance(only)
    refute toggled.is_active

    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    assert profile.primary_calendar_integration_id == nil
  end
end
