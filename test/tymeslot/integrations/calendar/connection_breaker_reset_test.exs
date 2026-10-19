defmodule Tymeslot.Integrations.Calendar.ConnectionBreakerResetTest do
  @moduledoc """
  A self-hosted calendar server's calls run through a breaker keyed by its
  host. Once it has opened, an integration whose syncs are paused sends that
  server no traffic, so nothing would close it again until it timed out; a
  connection test that reaches the server is the evidence that it is back.
  """

  # Host breakers are global processes shared with every other test, and
  # DataCase resets them in its setup.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :capture_log

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.Reconnection
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CalDAVAccountStub

  # A generic CalDAV integration on a Nextcloud-shaped URL: its client takes
  # the server type detected from the URL, so every call it makes trips a
  # `:nextcloud` breaker for the host, never a `:caldav` one.
  @calendar_path "/remote.php/dav/calendars/bob/a/"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    host = "dav-#{System.unique_integer([:positive])}.example.com"

    inserted =
      insert(:calendar_integration,
        provider: "caldav",
        base_url: "https://#{host}/remote.php/dav",
        calendar_paths: [@calendar_path]
      )

    # As every caller has it: read back, credentials decrypted.
    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)

    trip_host_breaker(:nextcloud, host)
    %{integration: integration, host: host}
  end

  test "a connection test that reaches the server closes its host breaker", %{
    integration: integration,
    host: host
  } do
    stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 207, body: ""}}
    end)

    assert {:ok, _message} = Connection.test_connection(integration, scope: :background)
    assert %{status: :closed} = CalendarCircuitBreaker.status(:nextcloud, host)
  end

  # Discovery is what a reconnect and a connection check run, and it goes
  # through the host breaker: an open one would refuse the very request that
  # can show the server is back, so these are let past it.
  test "a reconnect reaches a server its breaker refuses, and closes the breaker", %{
    integration: integration,
    host: host
  } do
    stub_discovery([@calendar_path])

    params = %{
      "url" => "https://#{host}/remote.php/dav",
      "username" => "bob",
      "password" => "pass"
    }

    assert {:ok, :needs_calendar_selection, payload} = Reconnection.reconnect(integration, params)
    assert [%{path: path}] = payload.calendars

    # A reconnect stores the server's origin, whose client names no server
    # type: the reconnected integration's traffic runs through the host's
    # `:caldav` breaker from here on, which an outage would have opened too.
    trip_host_breaker(:caldav, host)

    assert {:ok, updated} = Reconnection.finalise_account_change(integration, payload, [path])
    assert_sync_reaches(updated, host)
  end

  test "an Exchange connection test reaches a server its breaker refuses, and closes it" do
    host = "ews-#{System.unique_integer([:positive])}.example.com"

    inserted =
      insert(:calendar_integration,
        provider: "exchange",
        base_url: "https://#{host}/EWS/Exchange.asmx",
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        calendar_list: []
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    trip_host_breaker(:exchange, host)

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: ExchangeFixtures.find_folder_response()}}
    end)

    assert {:ok, _message} = Connection.test_connection(integration)
    assert %{status: :closed} = CalendarCircuitBreaker.status(:exchange, host)
  end

  # One iCloud account reaching iCloud says nothing about the failures every
  # other account on that host saw.
  test "a connection test leaves a server shared by many accounts alone" do
    inserted =
      insert(:calendar_integration,
        provider: "apple",
        base_url: "https://caldav.icloud.com",
        calendar_paths: ["/123/calendars/home/"]
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    trip_host_breaker(:apple, "caldav.icloud.com")

    stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 207, body: ""}}
    end)

    assert {:ok, _message} = Connection.test_connection(integration, scope: :background)
    assert %{status: :open} = CalendarCircuitBreaker.status(:apple, "caldav.icloud.com")
  end

  # The breaker closed has to be the one the integration's own traffic
  # trips, or a reconnect reports success while sync and discovery stay
  # refused until the breaker times out.
  # The sync worker builds its client from the stored row rather than through
  # the provider adapter. Its traffic has to trip the same breaker the reset
  # closes, or a server that came back stays refused to sync until the
  # breaker times out.
  # A detected server type need not be a provider of its own: ownCloud is
  # only ever a generic CalDAV integration, and its breaker is still the one
  # to close.
  # Discovery answers from a cache for a while. A check served from it never
  # reached the server, so it can say nothing about whether the server is
  # back, and must not close the breaker as though it had.
  test "a connection test that fails leaves the breaker open", %{
    integration: integration,
    host: host
  } do
    stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 401, body: ""}}
    end)

    assert {:error, _reason} = Connection.test_connection(integration, scope: :background)
    assert %{status: :open} = CalendarCircuitBreaker.status(:nextcloud, host)
  end

  # Fetches the integration's events as a sync does, and asserts the request
  # reached the server rather than being refused by an open breaker. Leaves a
  # recording stub in place for any further request.
  defp assert_sync_reaches(integration, host) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:reached, method, URI.parse(url).host})

      case method do
        :report -> {:ok, %Req.Response{status: 207, body: ~s(<D:multistatus xmlns:D="DAV:"/>)}}
        :propfind -> CalDAVAccountStub.answer(%{calendars: [@calendar_path]}, method, url, body)
      end
    end)

    {:ok, client} = ProviderAdapter.new_client_from_integration(integration)
    assert {:ok, _events} = ProviderAdapter.get_events(client)
    assert_received {:reached, :report, ^host}
  end

  defp stub_discovery(calendars) do
    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      CalDAVAccountStub.answer(%{calendars: calendars}, method, url, body)
    end)
  end

  defp trip_host_breaker(provider, host) do
    threshold = CalendarCircuitBreaker.get_config(provider).failure_threshold

    for _attempt <- 1..threshold do
      CalendarCircuitBreaker.with_breaker(provider, [host: host], fn ->
        {:provider_error, :unreachable}
      end)
    end

    assert %{status: :open} = CalendarCircuitBreaker.status(provider, host)
  end
end
