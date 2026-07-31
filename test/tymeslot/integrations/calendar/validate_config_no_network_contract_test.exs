defmodule Tymeslot.Integrations.Calendar.ValidateConfigNoNetworkContractTest do
  @moduledoc """
  Locks in the contract described on `Tymeslot.Integrations.Calendar.Provider`:
  `validate_config/1` is structural only and never performs network I/O.

  It used to be that six of the seven CalDAV-family providers folded a live
  connectivity probe into `validate_config/1`, so `Calendar.Creation`'s
  "validate, then test" sequence during integration creation silently probed
  the user-supplied host twice — once completely un-rate-limited. This test
  iterates every member of `ProviderConfig.caldav_based_providers/0` with a
  complete, well-formed config and asserts `Tymeslot.HTTPClientMock` is never
  called, so a provider that regresses back to probing the network fails
  loudly here rather than silently double-charging a rate limit bucket.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :calendar

  import Mox

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  setup :verify_on_exit!

  # One complete, well-formed config per CalDAV-family provider, matching
  # each provider's own `config_schema/0` / `validate_config/1` tests.
  @example_urls %{
    caldav: "https://caldav.example.com",
    radicale: "https://radicale.example.com:5232",
    nextcloud: "https://cloud.example.com",
    zimbra: "https://mail.example.com",
    mailbox_org: "https://dav.mailbox.org",
    apple: "https://caldav.icloud.com",
    baikal: "https://baikal.example.com/dav.php"
  }

  describe "validate_config/1 never touches the network" do
    for provider <- ProviderConfig.caldav_based_providers() do
      test "#{provider} accepts a complete config without an HTTP call" do
        provider = unquote(provider)
        module = ProviderConfig.get_provider_module(provider)
        base_url = Map.fetch!(@example_urls, provider)

        config = %{
          base_url: base_url,
          username: "user",
          password: "pass"
        }

        # Any call here means a regression reintroduced a live connectivity
        # probe into `validate_config/1` — fail loudly rather than let the
        # DataCase's benign HTTP stub mask it as a structural failure.
        expect(Tymeslot.HTTPClientMock, :request, 0, fn _method, _url, _body, _headers, _opts ->
          flunk("#{provider}.validate_config/1 must not perform network I/O")
        end)

        expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
          flunk("#{provider}.validate_config/1 must not perform network I/O")
        end)

        assert :ok = module.validate_config(config)
      end
    end
  end
end
