defmodule Tymeslot.Integrations.Video.ProviderConfigLookupTest do
  # async: false: one case switches a provider off in application config.
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.GoogleMeetProvider
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider

  setup :verify_on_exit!

  @known [:custom, :google_meet, :jitsi, :kmeet, :mirotalk, :nextcloud_talk, :teams, :zoom]

  describe "the provider table" do
    test "covers every known provider with a loadable module, a name and a config schema" do
      assert Enum.sort(ProviderConfig.known_providers()) == @known

      # kMeet has a fixed host and nothing for the user to configure.
      zero_config = [:kmeet]

      incomplete =
        Enum.reject(ProviderConfig.known_providers(), fn provider ->
          {:ok, module} = ProviderConfig.get_provider(provider)

          Code.ensure_loaded?(module) and
            ProviderConfig.display_name(provider) != "Unknown Provider" and
            (provider in zero_config or map_size(module.config_schema()) > 0)
        end)

      assert incomplete == []
    end

    test "answers an unknown provider with an error" do
      assert {:error, "Unknown video provider type: unknown"} =
               ProviderConfig.get_provider(:unknown)

      assert ProviderConfig.display_name(:unknown) == "Unknown Provider"
    end
  end

  # Switching a provider off stops new connections only: integrations already
  # connected to it keep their rooms working until they are disconnected.
  describe "a provider switched off in config" do
    setup do
      prior = Application.fetch_env(:tymeslot, :video_providers)
      Application.put_env(:tymeslot, :video_providers, %{zoom: %{enabled: false}})

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:tymeslot, :video_providers, value)
          :error -> Application.delete_env(:tymeslot, :video_providers)
        end
      end)
    end

    test "is refused where something new starts" do
      assert {:error, :unknown} = ProviderConfig.parse("zoom")
      refute :zoom in ProviderConfig.all_providers()
    end

    test "still resolves for the integrations already connected to it" do
      assert {:ok, :zoom} = ProviderConfig.parse_known("zoom")
      assert {:ok, ZoomProvider} = ProviderConfig.get_provider(:zoom)
    end
  end

  describe "room_creation_budget_ms/1" do
    test "answers the budget the provider itself declares" do
      for {provider, module} <- [
            google_meet: GoogleMeetProvider,
            mirotalk: MiroTalkProvider,
            nextcloud_talk: NextcloudTalkProvider,
            teams: TeamsProvider,
            zoom: ZoomProvider
          ] do
        assert ProviderConfig.room_creation_budget_ms(provider) ==
                 module.room_creation_budget_ms()
      end
    end

    test "answers nothing to wait for on providers that build their link without a network call" do
      for provider <- [:custom, :jitsi, :kmeet] do
        assert ProviderConfig.room_creation_budget_ms(provider) == 0
      end
    end

    test "answers the largest declared budget without a provider, or for an unknown one" do
      largest =
        Enum.max(
          Enum.map(ProviderConfig.known_providers(), &ProviderConfig.room_creation_budget_ms/1)
        )

      assert ProviderConfig.room_creation_budget_ms() == largest
      assert ProviderConfig.room_creation_budget_ms(:unknown) == largest
    end

    test "a provider's own budget can be well below the largest" do
      assert ProviderConfig.room_creation_budget_ms(:nextcloud_talk) <
               ProviderConfig.room_creation_budget_ms()
    end
  end

  describe "ProviderAdapter.test_connection/2" do
    # This probe runs on a schedule against a self-hosted MiroTalk server the
    # customer owns, so the number of requests it costs them is part of the
    # contract.
    test "issues exactly one request to the MiroTalk server per probe" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        Agent.update(counter, &(&1 + 1))
        {:ok, %Req.Response{status: 200}}
      end)

      assert {:ok, _message} = ProviderAdapter.test_connection(:mirotalk, config)
      assert Agent.get(counter, & &1) == 1
    end

    # No HTTP expectation: a config missing its server is refused before any
    # request.
    test "refuses a MiroTalk config missing its server address" do
      assert {:error, {_tag, message}} =
               ProviderAdapter.test_connection(:mirotalk, %{api_key: "test_key"})

      assert message =~ "Base URL is required"
    end

    test "answers an unknown provider with an error" do
      assert {:error, _reason} = ProviderAdapter.test_connection(:unknown, %{})
    end
  end
end
