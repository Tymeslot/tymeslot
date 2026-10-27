defmodule Tymeslot.Integrations.Video.Providers.ServerUrlTest do
  @moduledoc """
  The address of a self-hosted video server (MiroTalk, Jitsi, Nextcloud Talk)
  is checked by one function, so the three providers refuse the same shapes
  and differ only in when plain http is allowed, and whether the check leaves
  the private-address switch to the schema.
  """

  # Not async: the private-address switch is application config.
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Tymeslot.Integrations.Video.Providers.LinkRoom

  setup do
    with_config(:tymeslot, :allow_private_ips_for_video, false)
    :ok
  end

  describe "validate_server_url/2" do
    test "accepts a server address, on a sub-path too" do
      assert :ok = LinkRoom.validate_server_url("https://meet.example.com")
      assert :ok = LinkRoom.validate_server_url("https://example.com/jitsi")
    end

    test "refuses a missing address" do
      assert {:error, "Base URL is required"} = LinkRoom.validate_server_url(nil)
      assert {:error, "Base URL is required"} = LinkRoom.validate_server_url("")
    end

    test "refuses a login name or password in the address" do
      assert {:error, message} =
               LinkRoom.validate_server_url("https://user:pass@meet.example.com")

      assert message =~ "cannot contain a login name or password"
    end

    test "refuses a query string or a fragment" do
      for url <- ["https://meet.example.com/?room=1", "https://meet.example.com/#top"] do
        assert {:error, message} = LinkRoom.validate_server_url(url)
        assert message =~ "cannot contain a query string (?) or a fragment (#)"
      end
    end

    test "refuses whitespace inside the address" do
      assert {:error, message} = LinkRoom.validate_server_url("https://meet example.com")
      assert message =~ "cannot contain spaces"
    end

    test "refuses a private address unless the operator allows them" do
      assert {:error, "Private or local network addresses are not allowed"} =
               LinkRoom.validate_server_url("http://192.168.1.20")

      with_config(:tymeslot, :allow_private_ips_for_video, true)
      assert :ok = LinkRoom.validate_server_url("http://192.168.1.20")
    end

    test "leaves the switch to a caller that asks it to" do
      assert :ok = LinkRoom.validate_server_url("http://192.168.1.20", private: :unchecked)
    end

    test "refuses plain http to a public host only when asked to" do
      assert :ok = LinkRoom.validate_server_url("http://meet.example.com")

      assert {:error, "Use https"} =
               LinkRoom.validate_server_url("http://meet.example.com",
                 https: :for_public,
                 https_error_message: "Use https"
               )

      with_config(:tymeslot, :allow_private_ips_for_video, true)
      assert :ok = LinkRoom.validate_server_url("http://localhost:8443", https: :for_public)
    end
  end
end
