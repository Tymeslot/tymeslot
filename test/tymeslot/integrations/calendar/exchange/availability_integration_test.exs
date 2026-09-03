defmodule Tymeslot.Integrations.Calendar.Exchange.AvailabilityIntegrationTest do
  @moduledoc """
  Exercises the whole path an Exchange mailbox's busy time travels to reach a
  booking page: `ClientManager.clients/1` resolving the integration to the
  whole-mailbox client `build_client_configs/1` produces,
  `Exchange.Provider.list_events/2` answering it from the local event cache,
  and the slot engine dropping the slots that interval covers.

  The HTTP client is stubbed to `flunk/1` for the whole module, so the two
  halves of the design are pinned by the same tests: the cache is read, and
  the network is not. A regression that puts the live `FindItem`/`GetItem`
  read back behind the callback fails here on the flunk rather than on a
  subtle difference in the events returned.
  """

  use Tymeslot.DataCase, async: false

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  @moduletag :integration
  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Security.Encryption
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  setup do
    # The test environment routes every calendar fetch to `CalendarMock`; the
    # booking page has to reach the real provider read for any of this to mean
    # anything.
    with_config(:tymeslot, :calendar_module, nil)

    test_pid = self()

    # `Tymeslot.DataCase` installs a benign transport-error stub. Replacing it
    # is the point of this module: an Exchange availability read that reaches
    # the network must fail the test, not degrade quietly.
    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      send(test_pid, :live_http_call)
      flunk("the availability path made a live EWS call; it must read the cache")
    end)

    %{user: user, profile: profile} = create_bookable_profile()

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: "https://mail.example.com/EWS/Exchange.asmx",
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        calendar_list: [],
        is_active: true
      )

    %{user: user, profile: profile, integration: integration}
  end

  describe "ClientManager.clients/1 for an Exchange mailbox" do
    test "yields one whole-mailbox client carrying the integration id", %{
      user: user,
      integration: integration
    } do
      # `ProviderRegistry.create_client/3` round-trips the config
      # `build_client_configs/1` returns through `new/1`, so this asserts the
      # shape that actually reaches `list_events/2`. Losing the integration id
      # on that hop is what would leave the cache read with nothing to look up.
      assert [%{provider_type: :exchange, client: client, provider_module: Provider}] =
               ClientManager.clients(user.id)

      assert client.calendar_integration_id == integration.id
    end
  end

  describe "list_events/2" do
    test "refuses a client that names no integration rather than reporting a free diary" do
      assert {:error, :no_calendar_integration_id} =
               Provider.list_events(%{base_url: "https://mail.example.com/EWS/Exchange.asmx"},
                 start_time: DateTime.utc_now(),
                 end_time: DateTime.add(DateTime.utc_now(), 7, :day)
               )

      refute_received :live_http_call
    end
  end

  describe "a cached busy interval on the booking page" do
    test "removes every slot the schedule would otherwise offer, touching no network", %{
      user: user,
      profile: profile,
      integration: integration
    } do
      busy_date = next_bookable_weekday(10)
      free_date = next_bookable_weekday(20)

      cache_row(integration, EventRole.busy_only(), busy_date, "exchange-busy-1")

      # Anchor: the schedule has to offer something before "offers nothing" on
      # the busy day says anything at all.
      assert {:ok, free_slots} = slots_for(free_date, user, profile)

      assert free_slots != [],
             "the schedule offered nothing even before the busy interval was applied"

      assert {:ok, busy_slots} = slots_for(busy_date, user, profile)

      assert busy_slots == [],
             "the mailbox was busy all day yet slots were still offered: #{inspect(busy_slots)}"

      refute_received :live_http_call
    end

    test "an item row the provider knows to be incomplete never blocks a slot", %{
      user: user,
      profile: profile,
      integration: integration
    } do
      # A `display_only` row is a `FindItem`/`GetItem` result. On some servers a
      # recurring series comes back as a single master dated to its first
      # occurrence, so blocking on those dates frees up every later occurrence
      # and blocks a day the mailbox may well be free. The availability read
      # must not see them at all.
      item_date = next_bookable_weekday(30)

      cache_row(integration, EventRole.display_only(), item_date, "exchange-item-1")

      assert {:ok, slots} = slots_for(item_date, user, profile)

      assert slots != [],
             "an incomplete item row reached availability and closed the day"

      refute_received :live_http_call
    end
  end

  # --- Helpers ---

  # The whole business day the bookable profile offers (11:00–17:00 Etc/UTC),
  # so a row covering it leaves no slot behind for a rounding difference to
  # rescue.
  defp cache_row(integration, role, date, uid) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "exchange",
      provider_calendar_id: "calendar",
      role: role,
      uid: uid,
      summary: "Busy",
      all_day: false,
      start_at: DateTime.new!(date, ~T[11:00:00.000000], "Etc/UTC"),
      end_at: DateTime.new!(date, ~T[17:00:00.000000], "Etc/UTC")
    )
  end

  defp slots_for(date, user, profile) do
    AvailabilityHelpers.get_available_slots(
      Date.to_iso8601(date),
      30,
      "Etc/UTC",
      user.id,
      profile
    )
  end
end
