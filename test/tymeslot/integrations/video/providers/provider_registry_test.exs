defmodule Tymeslot.Integrations.Video.Providers.ProviderRegistryTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  import Mox
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  setup :verify_on_exit!

  describe "list_providers/0" do
    test "returns list of all registered video providers" do
      assert Enum.sort(ProviderRegistry.list_providers()) ==
               [:custom, :google_meet, :jitsi, :kmeet, :mirotalk, :nextcloud_talk, :teams, :zoom]

      assert ProviderRegistry.provider_count() == 8
    end
  end

  describe "get_provider/1" do
    test "returns provider module for valid mirotalk provider" do
      assert {:ok, module} = ProviderRegistry.get_provider(:mirotalk)
      assert module == Tymeslot.Integrations.Video.Providers.MiroTalkProvider
    end

    test "returns provider module for valid google_meet provider" do
      assert {:ok, module} = ProviderRegistry.get_provider(:google_meet)
      assert module == Tymeslot.Integrations.Video.Providers.GoogleMeetProvider
    end

    test "returns provider module for valid teams provider" do
      assert ProviderRegistry.get_provider(:teams) ==
               {:ok, Tymeslot.Integrations.Video.Providers.TeamsProvider}
    end

    test "returns ZoomProvider for :zoom" do
      assert {:ok, Tymeslot.Integrations.Video.Providers.ZoomProvider} =
               ProviderRegistry.get_provider(:zoom)
    end

    test "returns provider module for valid custom provider" do
      assert {:ok, module} = ProviderRegistry.get_provider(:custom)
      assert module == Tymeslot.Integrations.Video.Providers.CustomProvider
    end

    test "returns error for unknown video provider" do
      assert {:error, message} = ProviderRegistry.get_provider(:unknown)
      assert String.contains?(message, "Unknown video provider")
    end
  end

  describe "get_provider!/1" do
    test "returns provider module for valid provider" do
      module = ProviderRegistry.get_provider!(:mirotalk)
      assert module == Tymeslot.Integrations.Video.Providers.MiroTalkProvider
    end

    test "raises for unknown provider" do
      assert_raise ArgumentError, fn ->
        ProviderRegistry.get_provider!(:invalid)
      end
    end
  end

  describe "validate_provider/1" do
    test "validates and returns atom for valid string provider" do
      assert {:ok, :mirotalk} = ProviderRegistry.validate_provider("mirotalk")
      assert {:ok, :google_meet} = ProviderRegistry.validate_provider("google_meet")
      assert {:ok, :custom} = ProviderRegistry.validate_provider("custom")
    end

    test "validates and returns atom for valid atom provider" do
      assert {:ok, :mirotalk} = ProviderRegistry.validate_provider(:mirotalk)
      assert {:ok, :google_meet} = ProviderRegistry.validate_provider(:google_meet)
    end

    test "returns error for invalid video provider" do
      assert {:error, message} = ProviderRegistry.validate_provider("invalid")
      assert String.contains?(message, "Invalid")
    end
  end

  describe "test_provider_connection/2" do
    test "tests mirotalk connection with valid config" do
      config = %{
        api_key: "test_key",
        base_url: "https://mirotalk.example.com"
      }

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      result = ProviderRegistry.test_provider_connection(:mirotalk, config)
      assert {:ok, _result} = result
    end

    # This probe runs on a schedule against a self-hosted MiroTalk server the
    # customer owns, so the number of requests it costs them is part of the
    # contract. `validate_config/1` must stay a pure structural check, leaving
    # `perform_connection_test/1` as the single caller that touches the network.
    test "issues exactly one request to the mirotalk server per probe" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        Agent.update(counter, &(&1 + 1))
        {:ok, %Req.Response{status: 200}}
      end)

      assert {:ok, _message} = ProviderRegistry.test_provider_connection(:mirotalk, config)
      assert Agent.get(counter, & &1) == 1
    end

    test "returns error for missing required config" do
      config = %{api_key: "test_key"}

      result = ProviderRegistry.test_provider_connection(:mirotalk, config)
      assert {:error, _reason} = result
    end

    test "returns error for unknown provider" do
      config = %{}

      assert {:error, _reason} = ProviderRegistry.test_provider_connection(:unknown, config)
    end
  end

  describe "list_providers_with_metadata/0" do
    test "returns metadata for all video providers" do
      providers = ProviderRegistry.list_providers_with_metadata()

      # Check metadata structure
      assert mirotalk = Enum.find(providers, fn p -> p.type == :mirotalk end)
      assert mirotalk.module == Tymeslot.Integrations.Video.Providers.MiroTalkProvider
      assert mirotalk.display_name == "MiroTalk P2P"
      assert Enum.sort(Map.keys(mirotalk.config_schema)) == [:api_key, :base_url]
    end

    test "every provider carries a loadable module, a display name and a config schema" do
      providers = ProviderRegistry.list_providers_with_metadata()

      assert Enum.sort(Enum.map(providers, & &1.type)) ==
               [:custom, :google_meet, :jitsi, :kmeet, :mirotalk, :nextcloud_talk, :teams, :zoom]

      # kMeet is the one deliberate exception: it has a fixed host and nothing
      # for the user to configure, so its config_schema is legitimately empty.
      zero_config = [:kmeet]

      assert Enum.reject(providers, &Code.ensure_loaded?(&1.module)) == []
      assert Enum.reject(providers, &(String.length(&1.display_name) > 0)) == []

      assert Enum.reject(
               providers,
               &(&1.type in zero_config or map_size(&1.config_schema) > 0)
             ) == []
    end

    test "includes capabilities metadata for video providers" do
      providers = ProviderRegistry.list_providers_with_metadata()

      Enum.each(providers, fn provider ->
        assert Map.has_key?(provider, :capabilities)
      end)
    end
  end

  describe "default_provider/0" do
    test "returns the default video provider" do
      assert ProviderRegistry.default_provider() == :mirotalk
    end
  end

  describe "provider_supported?/1" do
    test "returns true for supported video providers" do
      assert ProviderRegistry.provider_supported?(:mirotalk)
      assert ProviderRegistry.provider_supported?(:google_meet)
      assert ProviderRegistry.provider_supported?(:custom)
      # Teams provider may not be available in all environments
    end

    test "returns false for unsupported video providers" do
      refute ProviderRegistry.provider_supported?(:unknown)
      refute ProviderRegistry.provider_supported?(:invalid)
    end
  end

  describe "providers_with_capability/1" do
    test "filters providers by specific capability" do
      # MiroTalk, Google Meet, Teams, Zoom, kMeet, Jitsi and Nextcloud Talk
      # declare screen_sharing; only the custom provider does not.
      assert Enum.sort(ProviderRegistry.providers_with_capability(:screen_sharing)) ==
               [:google_meet, :jitsi, :kmeet, :mirotalk, :nextcloud_talk, :teams, :zoom]
    end

    test "returns empty list for non-existent capability" do
      assert ProviderRegistry.providers_with_capability(:nonexistent_feature) == []
    end
  end

  describe "ProviderConfig integration with Zoom" do
    test "providers_map/0 includes Zoom when enabled" do
      map = ProviderConfig.providers_map()
      assert map[:zoom] == Tymeslot.Integrations.Video.Providers.ZoomProvider
    end

    test "all_providers_with_dev/0 lists Zoom among providers" do
      assert :zoom in ProviderConfig.all_providers_with_dev()
    end

    test "display_name/1 returns Zoom for :zoom" do
      assert ProviderConfig.display_name(:zoom) == "Zoom"
    end
  end
end
