defmodule Tymeslot.Integrations.Calendar.Ics.AvailabilityIntegrationTest do
  @moduledoc """
  Exercises the read path a subscribed feed's cached events travel through to
  reach availability: `ClientManager.clients/1` resolving the integration to
  a client built by `Ics.Provider.new/1` (the config `build_client_configs/1`
  produces never reaches `list_events/2` directly — `ProviderRegistry`
  round-trips it through `new/1` first), and the cached event coming back out
  through the real fan-out (`Runtime.EventQueries`) rather than a unit test
  calling `Provider.list_events/2` with a hand-built client.

  A regression that stops `new/1` threading `calendar_integration_id` through
  (or a `ClientManager` change that resolves the subscription via some other
  path) would silently fail `list_events/2` open to `{:ok, []}` — no
  conflicts, no blocked slots — without either of the read failing.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integration
  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Ics.Provider, as: IcsProvider
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Runtime.EventQueries
  alias Tymeslot.Security.Encryption

  @feed_url "https://feeds.example.com/secret-address/team.ics"

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt(@feed_url),
        is_active: true
      )

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "ics_url",
      provider_calendar_id: "subscription",
      uid: "blocked-slot@example.com",
      summary: "Publisher busy block",
      start_at: ~U[2026-08-10 09:00:00.000000Z],
      end_at: ~U[2026-08-10 10:00:00.000000Z],
      all_day: false
    )

    %{user: user, integration: integration}
  end

  describe "ClientManager.clients/1 for a subscribed feed" do
    test "yields the client Ics.Provider.new/1 builds, carrying the integration id through", %{
      user: user,
      integration: integration
    } do
      assert [%{provider_type: :ics_url, client: client, provider_module: IcsProvider}] =
               ClientManager.clients(user.id)

      # `ProviderRegistry.create_client/3` calls `new/1` on the config
      # `build_client_configs/1` returns; assert the shape `new/1` actually
      # produces (rather than the pre-`new/1` config) so a regression that
      # drops `calendar_integration_id` on that hop fails here.
      assert client.calendar_integration_id == integration.id
      assert client.feed_url == @feed_url
      assert client.calendar_path == "subscription"
    end
  end

  describe "the subscribed feed's cached events block availability" do
    test "the cached event reaches the real read path end-to-end", %{user: user} do
      assert {:ok, events} =
               EventQueries.get_events_for_range_fresh(user.id, ~D[2026-08-01], ~D[2026-08-20])

      assert Enum.any?(events, &(&1.uid == "blocked-slot@example.com"))
    end

    test "a range that excludes the cached event's window returns no events for it", %{
      user: user
    } do
      assert {:ok, events} =
               EventQueries.get_events_for_range_fresh(user.id, ~D[2026-09-01], ~D[2026-09-30])

      refute Enum.any?(events, &(&1.uid == "blocked-slot@example.com"))
    end
  end
end
