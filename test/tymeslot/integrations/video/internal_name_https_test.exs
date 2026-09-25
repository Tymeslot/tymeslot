defmodule Tymeslot.Integrations.Video.InternalNameHttpsTest do
  @moduledoc """
  A self-hosted Nextcloud Talk or Jitsi server beside Tymeslot, on a Docker
  service name or a home-network name, may be entered with plain http once the
  operator allows private video addresses (`ALLOW_PRIVATE_IPS_FOR_VIDEO`).
  The name's shape decides, never a DNS lookup, and a public name still needs
  https, as does every name while the opt-in is off.
  """

  # Not async: the opt-in is application config.
  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :video
  @moduletag :security

  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider

  @internal_servers [
    "http://nextcloud",
    "http://talk.local",
    "http://talk.lan",
    "http://talk.internal",
    "http://talk.home.arpa"
  ]

  setup do
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :allow_private_ips_for_video, nil)
    :ok
  end

  describe "Nextcloud Talk" do
    test "accepts plain http to an internal name once private video addresses are allowed" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      for server <- @internal_servers do
        assert {server, :ok} == {server, NextcloudTalkProvider.validate_config(talk(server))}
      end
    end

    test "still asks for https on a public name" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      assert {:error, message} =
               NextcloudTalkProvider.validate_config(talk("http://cloud.example.com"))

      assert message =~ "https://"
    end

    test "asks for https on an internal name while private video addresses are not allowed" do
      for server <- @internal_servers do
        assert {:error, message} = NextcloudTalkProvider.validate_config(talk(server))
        assert message =~ "https://"
      end
    end
  end

  describe "Jitsi with token credentials" do
    test "accepts plain http to an internal name once private video addresses are allowed" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      for server <- @internal_servers do
        assert {server, :ok} == {server, JitsiProvider.validate_config(jitsi(server))}
      end
    end

    test "still asks for https on a public name" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      assert {:error, message} = JitsiProvider.validate_config(jitsi("http://meet.example.com"))
      assert message =~ "https://"
    end

    test "asks for https on an internal name while private video addresses are not allowed" do
      for server <- @internal_servers do
        assert {:error, message} = JitsiProvider.validate_config(jitsi(server))
        assert message =~ "https://"
      end
    end
  end

  defp talk(server),
    do: %{
      base_url: server,
      client_id: "organiser",
      client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
    }

  defp jitsi(server),
    do: %{base_url: server, client_id: "tymeslot", client_secret: String.duplicate("s", 32)}
end
