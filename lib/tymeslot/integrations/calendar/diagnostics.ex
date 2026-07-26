defmodule Tymeslot.Integrations.Calendar.Diagnostics do
  @moduledoc """
  Direct provider-event operations and ephemeral integration builders used by
  developer tooling (the `mix calendar_audit` task) and diagnostic flows that
  bypass the normal sync pipeline.

  Application code should call the public `Tymeslot.Integrations.Calendar`
  facade rather than this module directly.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.EventsRead
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.{CaldavCommon, ProviderAdapter}
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Security.Encryption

  @type integration :: CalendarIntegrationSchema.t()

  @doc """
  Creates an event on the integration's calendar provider.

  Returns `{:ok, event_id}` where `event_id` is a string identifier, or
  `{:error, reason}`.
  """
  @spec create_provider_event(integration(), map()) :: {:ok, any()} | {:error, any()}
  def create_provider_event(%CalendarIntegrationSchema{} = integration, event_attrs) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      adapter_client.provider_module.create_event(
        adapter_client.client,
        normalise_event_attrs(event_attrs)
      )
    end
  end

  @doc """
  Diagnostic-only: PUTs a pre-built iCalendar payload into a CalDAV-family
  integration's primary calendar, bypassing `ICalBuilder`.

  Used by `mix calendar_audit` to exercise adversarial server-generated
  payloads (e.g. Zimbra-style `TZID="Europe/Brussels"`) that Tymeslot's own
  writer never produces, so the audit can verify our parser handles them.
  Not intended for application use.
  """
  @spec put_raw_caldav_ical(integration(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, any()}
  def put_raw_caldav_ical(
        %CalendarIntegrationSchema{provider: provider} = integration,
        uid,
        ical_content
      ) do
    with {:ok, provider_atom} <- ProviderConfig.validate_provider(provider),
         {:caldav?, true} <- {:caldav?, ProviderConfig.caldav_based?(provider_atom)},
         {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      CaldavCommon.put_raw_event(adapter_client.client, uid, ical_content)
    else
      {:caldav?, false} -> {:error, :unsupported_provider}
      other -> other
    end
  end

  @doc """
  Fetches raw events from the provider and normalises them into `CalendarEvent` structs.

  Returns `{:ok, [CalendarEvent.t()]}` or `{:error, reason}`.
  """
  @spec fetch_and_normalise_provider_events(integration(), DateTime.t(), DateTime.t()) ::
          {:ok, list()} | {:error, any()}
  def fetch_and_normalise_provider_events(
        %CalendarIntegrationSchema{} = integration,
        range_start,
        range_end
      ) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      context = %{
        calendar_integration_id: integration.id,
        provider_calendar_id: integration.default_booking_calendar_id || "",
        synced_at: DateTime.utc_now(:microsecond)
      }

      opts = [start_time: range_start, end_time: range_end]

      with {:ok, raw_events} <-
             adapter_client.provider_module.list_events(adapter_client.client, opts) do
        adapter_client.provider_module.normalise_events(raw_events, context)
      end
    end
  end

  @doc """
  Fetches events via the fresh-fetch path — the same code path the availability
  calculator uses at runtime. Returns plain maps (not `CalendarEvent` structs).

  This is the counterpart to `fetch_and_normalise_provider_events/3`, which goes
  through the sync/normalisation pipeline. Comparing results between the two
  paths catches divergence bugs (e.g. one expands recurring events, the other
  does not).
  """
  @spec fetch_fresh_events(integration(), DateTime.t(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_fresh_events(%CalendarIntegrationSchema{} = integration, range_start, range_end) do
    clients = ClientManager.clients_for_integration(integration)

    results =
      Enum.map(clients, fn client ->
        EventsRead.fetch_events_with_fallback(client, range_start, range_end)
      end)

    successes = for {:ok, events, _path} <- results, event <- events, do: event
    success_count = Enum.count(results, &match?({:ok, _events, _path}, &1))

    if success_count == 0 and results != [] do
      {:error, :all_clients_failed}
    else
      {:ok, Enum.uniq_by(successes, &{&1[:uid], &1[:start_time]})}
    end
  end

  @doc """
  Updates an event on the integration's calendar provider.

  Returns `:ok`, `{:ok, result}`, or `{:error, reason}`.
  """
  @spec update_provider_event(integration(), String.t(), map()) ::
          :ok | {:ok, any()} | {:error, any()}
  def update_provider_event(%CalendarIntegrationSchema{} = integration, event_id, event_attrs) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      adapter_client.provider_module.update_event(
        adapter_client.client,
        event_id,
        normalise_event_attrs(event_attrs)
      )
    end
  end

  @doc """
  Deletes an event from the integration's calendar provider.

  Returns `:ok`, `{:ok, result}`, or `{:error, reason}`.
  """
  @spec delete_provider_event(integration(), String.t()) ::
          :ok | {:ok, any()} | {:error, any()}
  def delete_provider_event(%CalendarIntegrationSchema{} = integration, event_id) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      adapter_client.provider_module.delete_event(adapter_client.client, event_id, [])
    end
  end

  @doc """
  Performs a quick connectivity probe against the integration's provider.

  Delegates to the provider's `check_connectivity/1` callback. CalDAV providers
  send a PROPFIND request with a short timeout to verify reachability and
  authentication. OAuth providers return immediately since token validity is
  checked lazily on the first real API call.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_provider_connectivity(integration()) :: :ok | {:error, any()}
  def check_provider_connectivity(%CalendarIntegrationSchema{} = integration) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration),
         {:ok, _info} <- adapter_client.provider_module.check_connectivity(adapter_client.client) do
      :ok
    end
  end

  @doc """
  Tests the connection and returns display-friendly message.
  Delegates to Connection.test_connection/2 to centralize provider resolution.

  `:scope` distinguishes an interactive test from a scheduled background probe;
  see `Tymeslot.Integrations.Calendar.Connection.test_connection/2`.
  """
  @spec test_connection(integration(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(integration, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    result = Connection.test_connection(integration, opts)

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:tymeslot, :integration, :test_connection],
      %{duration: duration},
      %{provider: integration.provider, type: "calendar", success: match?({:ok, _result}, result)}
    )

    result
  end

  @doc """
  Builds an unpersisted `CalendarIntegrationSchema` struct for a Baikal
  ephemeral audit or test target — no database row is created or required.

  Owns the encryption and virtual-field details so callers (e.g. SaaS Mix
  tasks) only need to pass a plain config map. The returned struct is ready
  to be passed into any runtime path that accepts an integration struct.

  ## Example

      Diagnostics.build_ephemeral_baikal_integration(%{
        url: "http://localhost:8800/dav.php",
        username: "testuser",
        password: "testpass123",
        calendar_path: "/dav.php/calendars/testuser/default/"
      })

  """
  @spec build_ephemeral_baikal_integration(%{
          required(:url) => String.t(),
          required(:username) => String.t(),
          required(:password) => String.t(),
          required(:calendar_path) => String.t()
        }) :: CalendarIntegrationSchema.t()
  def build_ephemeral_baikal_integration(%{
        url: url,
        username: username,
        password: password,
        calendar_path: calendar_path
      }) do
    %CalendarIntegrationSchema{
      id: 0,
      provider: "baikal",
      name: "#{ProviderConfig.display_name(:baikal)} (#{URI.parse(url).host})",
      base_url: url,
      username_encrypted: Encryption.encrypt(username),
      password_encrypted: Encryption.encrypt(password),
      username: username,
      password: password,
      calendar_paths: [calendar_path],
      calendar_list: [],
      default_booking_calendar_id: calendar_path,
      verify_ssl: true,
      is_active: true,
      needs_reauth: false
    }
  end

  # Normalizes outbound event attrs for provider dispatch. Currently handles
  # the all-day `end_date == start_date` case: iCal, Google, and Outlook all
  # treat the end as exclusive for date-only events, so a single-day event
  # must have `end = start + 1`. Callers may pass `end = start` to express
  # "an event on that day"; this helper bridges the intent to the wire format.
  defp normalise_event_attrs(
         %{start_time: %Date{} = start_date, end_time: %Date{} = end_date} = attrs
       ) do
    if Date.compare(start_date, end_date) == :eq do
      %{attrs | end_time: Date.add(end_date, 1)}
    else
      attrs
    end
  end

  defp normalise_event_attrs(attrs), do: attrs
end
