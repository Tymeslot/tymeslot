defmodule Tymeslot.Integrations.Calendar.CrossProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  import Tymeslot.CrossProviderTestHelpers
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  @moduledoc """
  Cross-provider consistency tests for calendar integrations.

  Ensures all calendar providers implement required behavior callbacks
  and handle operations consistently.
  """

  # List of providers to test (excluding debug/demo providers)
  @production_providers [:caldav, :nextcloud, :radicale]

  @display_names %{caldav: "CalDAV", nextcloud: "Nextcloud", radicale: "Radicale"}

  # A public host that passes the SSRF guard, so the stubbed HTTP client is
  # what decides each provider's result below.
  @reachable_url "https://cal.example.com"

  # Every provider maps HTTP 401 onto its own copy, but all of them must
  # report it as an authentication problem rather than a generic failure.
  @unauthorized_results %{
    caldav: {:error, :unauthorized},
    nextcloud:
      {:error,
       "Authentication failed. Check your Nextcloud username and password. Consider using an app password."},
    radicale: {:error, "Authentication failed. Check your Radicale username and password."}
  }

  @success_results %{
    caldav: {:ok, "CalDAV connection successful"},
    nextcloud: {:ok, "Nextcloud connection successful"},
    radicale: {:ok, "Radicale connection successful"}
  }

  # The transport failure arrives as `%Mint.TransportError{reason: :timeout}`;
  # no provider may hand that struct back to its caller.
  @transport_error_results %{
    caldav: {:error, :timeout},
    nextcloud: {:error, :timeout},
    radicale: {:error, "Radicale error: :timeout"}
  }

  # Get production providers from registry (exclude debug/demo)
  defp production_providers do
    Enum.filter(ProviderRegistry.list_providers(), fn provider ->
      provider in @production_providers
    end)
  end

  describe "provider metadata consistency" do
    test "all providers return provider_type" do
      assert_providers_return_provider_type(ProviderRegistry, production_providers())
    end

    test "all providers return display_name" do
      assert_providers_return_display_name(ProviderRegistry, @display_names)
    end

    test "all providers return config_schema" do
      assert_providers_return_config_schema(ProviderRegistry, production_providers())
    end
  end

  describe "config schema consistency" do
    test "all CalDAV-based providers have base_url field" do
      caldav_providers = [:caldav, :nextcloud, :radicale]

      Enum.each(caldav_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        schema = provider_module.config_schema()

        # CalDAV providers should have base_url
        assert Map.has_key?(schema, :base_url)
        assert schema[:base_url][:type] == :string
        assert schema[:base_url][:required] == true
      end)
    end

    test "all credential-based providers have username and password fields" do
      credential_providers = [:caldav, :nextcloud, :radicale]

      Enum.each(credential_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        schema = provider_module.config_schema()

        # Should have username
        assert Map.has_key?(schema, :username)
        assert schema[:username][:type] == :string

        # Should have password
        assert Map.has_key?(schema, :password)
        assert schema[:password][:type] == :string
      end)
    end

    test "all credential-based providers have calendar_paths field" do
      credential_providers = [:caldav, :nextcloud, :radicale]

      Enum.each(credential_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        schema = provider_module.config_schema()

        # Should have calendar_paths
        assert Map.has_key?(schema, :calendar_paths)
      end)
    end
  end

  describe "connection validation consistency" do
    test "perform_connection_test reports rejected credentials as an auth failure" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 401, body: ""}}
        end)

        invalid_config = %{
          base_url: @reachable_url,
          username: "invalid",
          password: "invalid",
          calendar_paths: [],
          provider: provider_type
        }

        assert provider_module.perform_connection_test(invalid_config) ==
                 @unauthorized_results[provider_type]
      end)
    end

    test "perform_connection_test/1 is pure I/O — takes only the config, no caller options" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 207, body: ""}}
        end)

        config = %{
          base_url: @reachable_url,
          username: "test",
          password: "test",
          calendar_paths: [],
          provider: provider_type
        }

        # The arity is the point: the call below passes the config alone, and
        # the stubbed PROPFIND proves the probe really was issued rather than
        # the call being rejected for a missing options argument.
        assert provider_module.perform_connection_test(config) == @success_results[provider_type]
      end)
    end
  end

  describe "client creation consistency" do
    test "new/1 creates client for credential-based providers" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        config = %{
          base_url: "http://localhost:1",
          username: "test",
          password: "test",
          calendar_paths: []
        }

        client = provider_module.new(config)

        assert %{provider: ^provider_type, username: "test", password: "test"} = client
      end)
    end
  end

  describe "provider behavior consistency" do
    test "all providers reduce a transport failure to a sanitised reason" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        config = %{
          base_url: @reachable_url,
          username: "test",
          password: "test",
          calendar_paths: [],
          provider: provider_type
        }

        # The shared stub answers with %Mint.TransportError{reason: :timeout};
        # what each provider returns must be the reduced form pinned above,
        # never the raw struct, which would leak Mint internals into the UI.
        assert provider_module.perform_connection_test(config) ==
                 @transport_error_results[provider_type]
      end)
    end

    test "all providers return consistent error format" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        invalid_config = %{
          base_url: "http://localhost:1",
          username: "invalid",
          password: "invalid",
          calendar_paths: [],
          provider: provider_type
        }

        assert {:error, message} = provider_module.perform_connection_test(invalid_config)
        assert message =~ "Private or local network addresses are not allowed"
      end)
    end
  end

  describe "registry integration" do
    test "all production providers are registered correctly" do
      assert_providers_registered_correctly(ProviderRegistry, @production_providers)
    end

    test "provider metadata is accessible through registry" do
      assert_provider_metadata_accessible(ProviderRegistry, @production_providers)
    end

    test "provider validation works through registry" do
      assert_provider_validation_works(ProviderRegistry, @production_providers)
    end
  end
end
