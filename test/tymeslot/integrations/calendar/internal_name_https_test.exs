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

  defp caldav(server), do: %{base_url: server, username: "organiser", password: "secret"}
end
