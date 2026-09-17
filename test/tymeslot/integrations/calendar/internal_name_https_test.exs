defmodule Tymeslot.Integrations.Calendar.InternalNameHttpsTest do
  @moduledoc """
  A self-hosted CalDAV or Nextcloud calendar beside Tymeslot, on a Docker
  service name or a home-network name, may be entered with plain http once the
  operator allows private calendar addresses (`ALLOW_PRIVATE_IPS_FOR_CALENDAR`).
  The name's shape decides, never a DNS lookup, and a public name still needs
  https, as does every name while the opt-in is off.
  """

  # Not async: the opt-in is application config.
  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :security

  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CaldavProvider
  alias Tymeslot.Integrations.Calendar.CredentialFields
  alias Tymeslot.Integrations.Calendar.InputValidation

  @internal_servers [
    "http://nextcloud/remote.php/dav",
    "http://cloud.local/remote.php/dav",
    "http://cloud.lan/remote.php/dav",
    "http://cloud.internal/remote.php/dav",
    "http://cloud.home.arpa/remote.php/dav"
  ]

  setup do
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    :ok
  end

  describe "the Nextcloud and CalDAV connect form" do
    test "accepts plain http to an internal name once private calendar addresses are allowed" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      for server <- @internal_servers do
        assert {server, :ok} == {server, CredentialFields.validate_calendar_url(server)}
      end
    end

    test "still asks for https on a public name" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      assert {:error, message} =
               CredentialFields.validate_calendar_url("http://cloud.example.com/remote.php/dav")

      assert message =~ "HTTPS"
    end

    test "asks for https on an internal name while private calendar addresses are not allowed" do
      for server <- @internal_servers do
        assert {:error, message} = CredentialFields.validate_calendar_url(server)
        assert message =~ "HTTPS"
      end
    end
  end

  # Every calendar form reaches the https rule through
  # `CredentialFields.server_url/2`, whose shape check refused a host without a
  # dot before the rule could run. These go through the forms themselves.
  describe "the calendar connect forms" do
    test "accept a Docker service name over plain http once private calendar addresses are allowed" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      for server <- @internal_servers do
        assert {:ok, %{"url" => ^server}} =
                 InputValidation.validate_calendar_integration_form(credentials(server))

        assert {:ok, %{"url" => ^server}} =
                 InputValidation.validate_exchange_form(
                   Map.put(credentials(server), "mailbox", "organiser@example.com"),
                   []
                 )

        assert {:ok, ^server} = InputValidation.validate_single_field(:url, server)

        assert {:ok, %{"url" => ^server}} =
                 InputValidation.validate_calendar_discovery(credentials(server),
                   provider: :nextcloud
                 )
      end
    end

    test "refuse a Docker service name while private calendar addresses are not allowed" do
      server = "http://nextcloud/remote.php/dav"

      assert {:error, %{url: message}} =
               InputValidation.validate_calendar_integration_form(credentials(server))

      assert message =~ "valid server URL"

      assert {:error, %{url: ^message}} =
               InputValidation.validate_exchange_form(
                 Map.put(credentials(server), "mailbox", "organiser@example.com"),
                 []
               )

      assert {:error, ^message} = InputValidation.validate_single_field(:url, server)

      assert {:error, %{url: ^message}} =
               InputValidation.validate_calendar_discovery(credentials(server),
                 provider: :nextcloud
               )
    end

    test "still ask for https on a public name" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      assert {:error, %{url: message}} =
               InputValidation.validate_calendar_integration_form(
                 credentials("http://cloud.example.com/remote.php/dav")
               )

      assert message =~ "HTTPS"
    end
  end

  describe "the CalDAV provider's configuration check" do
    test "accepts plain http to an internal name once private calendar addresses are allowed" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      for server <- @internal_servers do
        assert {server, :ok} == {server, CaldavProvider.validate_config(caldav(server))}
      end
    end

    test "still asks for https on a public name" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      assert {:error, message} =
               CaldavProvider.validate_config(caldav("http://cloud.example.com/remote.php/dav"))

      assert message =~ "HTTPS"
    end

    test "asks for https on an internal name while private calendar addresses are not allowed" do
      for server <- @internal_servers do
        assert {:error, message} = CaldavProvider.validate_config(caldav(server))
        assert message =~ "HTTPS"
      end
    end
  end

  defp credentials(server),
    do: %{
      "name" => "Team cloud",
      "url" => server,
      "username" => "organiser",
      "password" => "secret-app-password"
    }

  defp caldav(server), do: %{base_url: server, username: "organiser", password: "secret"}
end
