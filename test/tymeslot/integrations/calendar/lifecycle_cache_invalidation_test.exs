defmodule Tymeslot.Integrations.Calendar.LifecycleCacheInvalidationTest do
  @moduledoc """
  Connecting, reconnecting, pausing, resuming and removing a calendar each
  drop the host's cached calendar events, so the next read (the booking page,
  the setup preview of the host's week) asks the provider again rather than
  serving what the calendars said before.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Reconnection
  alias Tymeslot.Security.Encryption

  setup do
    AvailabilityCache.clear_all()
    user = insert(:user)
    insert(:profile, user: user)
    %{user: user}
  end

  # Caches a read of the host's events, as a booking page or the preview
  # does, and returns a check of whether the next read still gets it.
  defp warm(user_id) do
    AvailabilityCache.clear_all()
    key = AvailabilityCache.booking_window_events_key(user_id)
    {:ok, [:before]} = AvailabilityCache.get_or_compute_events(key, fn -> {:ok, [:before]} end)

    fn ->
      {:ok, events} = AvailabilityCache.get_or_compute_events(key, fn -> {:ok, [:after]} end)
      events == [:before]
    end
  end

  defp caldav_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user.id,
        name: "Work",
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("secret"),
        calendar_paths: ["/calendars/alice/default/"],
        provider_account_id: "https://caldav.example.com||alice",
        is_active: true
      },
      overrides
    )
  end

  test "connecting a calendar drops the cached events", %{user: user} do
    still_cached? = warm(user.id)

    assert {:ok, _integration} = Management.insert_integration(caldav_attrs(user))

    refute still_cached?.()
  end

  test "pausing and switching a calendar back on each drop the cached events", %{user: user} do
    {:ok, integration} = Management.insert_integration(caldav_attrs(user))

    still_cached? = warm(user.id)
    assert {:ok, %{is_active: false}} = Management.pause_integration(integration)
    refute still_cached?.()

    still_cached? = warm(user.id)
    assert {:ok, %{is_active: true}} = Calendar.toggle_integration(user.id, integration.id)
    refute still_cached?.()
  end

  test "reconnecting a paused calendar drops the cached events", %{user: user} do
    {:ok, integration} = Management.insert_integration(caldav_attrs(user, %{is_active: false}))
    still_cached? = warm(user.id)

    discover = fn _provider, url, username, password ->
      {:ok,
       %{
         calendars: [
           %{"id" => "/calendars/alice/default/", "path" => "/calendars/alice/default/"}
         ],
         discovery_credentials: %{url: url, username: username, password: password}
       }}
    end

    assert {:ok, %CalendarIntegrationSchema{is_active: true}} =
             Reconnection.reconnect_and_resume_for_user(
               user.id,
               integration.id,
               %{
                 "url" => "https://caldav.example.com",
                 "username" => "alice",
                 "password" => "new"
               },
               discover: discover
             )

    refute still_cached?.()
  end

  test "an OAuth reconnect that switches a calendar back on drops the cached events",
       %{user: user} do
    {:ok, integration} = Management.insert_integration(caldav_attrs(user, %{is_active: false}))
    still_cached? = warm(user.id)

    assert {:ok, %{is_active: true}} =
             Management.reconnect_integration(integration, %{is_active: true})

    refute still_cached?.()
  end

  test "removing a calendar drops the cached events", %{user: user} do
    {:ok, integration} = Management.insert_integration(caldav_attrs(user))
    still_cached? = warm(user.id)

    assert {:ok, _result} =
             Calendar.delete_with_primary_reassignment_and_invalidate(user.id, integration.id)

    refute still_cached?.()
  end
end
