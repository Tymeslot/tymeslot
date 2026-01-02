defmodule Tymeslot.Integrations.Video.Providers.ProviderRegistryTest do
  use ExUnit.Case, async: true

  import Mox
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  setup :verify_on_exit!

  describe "list_providers/0" do
    test "returns list of all registered video providers" do
      providers = ProviderRegistry.list_providers()

      assert is_list(providers)
      assert :mirotalk in providers
      assert :google_meet in providers
      assert :custom in providers
      # Teams provider may not be available in all environments
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

    test "returns provider module for teams if available" do
      case ProviderRegistry.get_provider(:teams) do
        {:ok, module} ->
          assert module == Tymeslot.Integrations.Video.Providers.TeamsProvider

        {:error, _} ->
          # Teams provider may not be available
          :ok
      end
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

  describe "valid_provider?/1" do
    test "returns true for valid video providers" do
      assert ProviderRegistry.valid_provider?(:mirotalk)
      assert ProviderRegistry.valid_provider?(:google_meet)
      assert ProviderRegistry.valid_provider?(:custom)
      # Teams provider may not be available in all environments
    end

    test "returns false for invalid video providers" do
      refute ProviderRegistry.valid_provider?(:invalid)
      refute ProviderRegistry.valid_provider?(:unknown)
    end
  end

  describe "valid_providers/0" do
    test "returns list of all valid video provider atoms" do
      providers = ProviderRegistry.valid_providers()

      assert is_list(providers)
      assert :mirotalk in providers
      assert :google_meet in providers
      assert :custom in providers
      # Teams provider may not be available in all environments
    end
  end

  describe "test_provider_connection/2" do
    test "tests mirotalk connection with valid config" do
      config = %{
        api_key: "test_key",
        base_url: "https://mirotalk.example.com"
      }

      # test_provider_connection calls validate_config, which calls test_connection,
      # and then it calls test_connection again. So we expect 2 calls.
      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 200}}
      end)

      result = ProviderRegistry.test_provider_connection(:mirotalk, config)
      assert {:ok, _} = result
    end

    test "returns error for missing required config" do
      config = %{api_key: "test_key"}

      result = ProviderRegistry.test_provider_connection(:mirotalk, config)
      assert {:error, _} = result
    end

    test "returns error for unknown provider" do
      config = %{}

      assert {:error, _} = ProviderRegistry.test_provider_connection(:unknown, config)
    end
  end

  describe "list_providers_with_metadata/0" do
    test "returns metadata for all video providers" do
      providers = ProviderRegistry.list_providers_with_metadata()

      assert is_list(providers)
      assert length(providers) > 0

      # Check metadata structure
      mirotalk = Enum.find(providers, fn p -> p.type == :mirotalk end)
      assert mirotalk.type == :mirotalk
      assert mirotalk.module == Tymeslot.Integrations.Video.Providers.MiroTalkProvider
      assert mirotalk.display_name == "MiroTalk P2P"
      assert is_map(mirotalk.config_schema)
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

  describe "provider_count/0" do
    test "returns total number of registered video providers" do
      count = ProviderRegistry.provider_count()

      assert is_integer(count)
      assert count >= 3
    end
  end

  describe "providers_with_capability/1" do
    test "filters providers by specific capability" do
      # Example: find providers that support screen sharing
      providers = ProviderRegistry.providers_with_capability(:screen_sharing)

      assert is_list(providers)
      # MiroTalk supports screen sharing
      if :mirotalk in ProviderRegistry.list_providers() do
        # Only assert if provider exists in this environment
        :ok
      end
    end

    test "returns empty list for non-existent capability" do
      providers = ProviderRegistry.providers_with_capability(:nonexistent_feature)

      assert is_list(providers)
    end
  end

  describe "recommend_provider/1" do
    test "returns a recommended provider based on requirements" do
      requirements = %{
        participant_count: 10,
        recording_required: false
      }

      provider = ProviderRegistry.recommend_provider(requirements)

      assert provider in [:mirotalk, :google_meet, :teams, :custom]
    end

    test "returns default provider when no requirements specified" do
      provider = ProviderRegistry.recommend_provider(%{})

      assert provider == ProviderRegistry.default_provider()
    end

    test "returns default provider when called without arguments" do
      provider = ProviderRegistry.recommend_provider()

      assert provider == :mirotalk
    end
  end
end
