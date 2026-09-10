defmodule Tymeslot.Integrations.Calendar.Exchange.ClientConfigTest do
  # async: false because `Tymeslot.HttpTransportCase` (behind `ExchangeCase`)
  # points the global `:http_client_module` at the real HTTP client for the
  # duration of the module. That is application env, not process state, so an
  # async module running it takes the Mox stub away from every other async
  # test running beside it. Every other user of these templates is sync for
  # the same reason.
  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :security

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.ClientConfig
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Security.Encryption

  describe "credential redaction" do
    test "every client the provider hands out masks the password when inspected" do
      integration = integration()
      {:ok, from_new} = Provider.new(config(password: leak_canary()))

      clients =
        [
          from_new,
          Provider.transport_config(integration),
          Provider.build_booking_client_config(integration)
        ] ++
          Provider.build_client_configs(integration) ++
          Provider.item_client_configs(integration)

      # Anchors the refutation below: a client that never carried the password
      # would pass it for the wrong reason.
      assert Enum.reject(clients, &(&1.password == leak_canary())) == []
      assert Enum.filter(clients, &(inspect(&1) =~ leak_canary())) == []
    end

    test "stays masked when the client is nested in a larger term" do
      # The vector this exists for: OTP prints a crashing task's arguments
      # verbatim, and a client reaches that report inside a tuple, never alone.
      {:ok, client} = Provider.new(config(password: leak_canary()))
      report = {:fetch_events, [client, ~U[2026-09-08 00:00:00Z]], %{attempt: 1}}

      refute inspect(report) =~ leak_canary()
    end
  end

  describe "new/1" do
    test "refuses a key the struct does not declare" do
      # `struct/2` would drop it in silence and the behaviour it controlled
      # would revert to a default with nothing in the logs.
      assert_raise KeyError, fn -> ClientConfig.new(config(inbox_folder_id: "AAMkAD")) end
    end

    test "passes an existing config back unchanged" do
      # Provider callbacks take a client they already built, so the conversion
      # has to be idempotent rather than rebuild one from a struct.
      built = ClientConfig.new(integration())

      assert ClientConfig.new(built) == built
    end

    test "carries the two fields a CalDAV-shaped provider config leaves out" do
      # `to_provider_config/1` is shaped for the CalDAV family: without these
      # merged back on, an on-premises server with a self-signed certificate
      # is refused and the availability read has no mailbox to address.
      built = ClientConfig.new(integration(%{verify_ssl: false}))

      assert built.verify_ssl == false
      assert built.provider_account_email == "room@example.com"
    end

    test "decrypts the credentials the schema stores encrypted" do
      # A freshly loaded row has nil virtual fields, so a conversion that read
      # them directly would build a client with no credentials at all.
      built = ClientConfig.new(integration())

      assert built.username == "user@example.com"
      assert built.password == leak_canary()
    end
  end

  defp integration(overrides \\ %{}) do
    Map.merge(
      %CalendarIntegrationSchema{
        id: 1,
        provider: "exchange",
        base_url: "https://mail.example.com/EWS/Exchange.asmx",
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt(leak_canary()),
        provider_account_email: "room@example.com",
        verify_ssl: true,
        calendar_list: [
          %CalendarEntry{id: "cal-1", name: "Calendar", selected: true},
          %CalendarEntry{id: "cal-2", name: "Rooms", selected: true}
        ]
      },
      Map.new(overrides)
    )
  end
end
