defmodule Tymeslot.Integrations.Calendar.Diagnostics do
  @moduledoc """
  Direct provider-event operations and ephemeral integration builders used by
  developer tooling (the `mix calendar_audit` task) and diagnostic flows that
  bypass the normal sync pipeline.

  Application code should call the public `Tymeslot.Integrations.Calendar`
  facade rather than this module directly.

  One function here deliberately does something no application path may:
  `put_raw_caldav_ical/3` writes a payload the provider's own writer would
  never produce. It exists so a diagnostic can plant the fixture it then reads
  back, and it is named and documented so that reaching for it from
  application code reads as the mistake it would be.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventsRead
  alias Tymeslot.Integrations.Calendar.Exchange.FreeBusy
  alias Tymeslot.Integrations.Calendar.Exchange.Provider, as: ExchangeProvider
  alias Tymeslot.Integrations.Calendar.Exchange.Writes, as: ExchangeWrites
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

  For the CalDAV and OAuth families this pairs `list_events/2` with
  `normalise_events/2`, which holds only because their `list_events/2` answers
  the provider's own raw representation. It does **not** hold for the
  cache-backed providers, whose `list_events/2` reads the local event cache and
  hands back plain maps their normaliser was never defined over.

  The two cache-backed providers are handled differently from each other, which
  is deliberate. `ics_url` has no live read of its own to substitute, so it
  answers `{:error, {:no_raw_representation, provider}}` rather than crashing
  inside a parser; probe it through `fetch_fresh_events/3`, which consumes
  exactly the shape it returns. `exchange` does have one — the item read the
  sync worker uses — so it is dispatched to `fetch_exchange_items/3` below,
  which reads the server rather than the cache. That is what the audit wants
  from it: a cache read would only report what a previous sync happened to
  write, and an ephemeral integration has no cache at all.

  Connectivity for any provider is `check_provider_connectivity/1`, which asks
  `check_connectivity/1` rather than inferring reachability from a fetch.
  """
  @spec fetch_and_normalise_provider_events(integration(), DateTime.t(), DateTime.t()) ::
          {:ok, list()} | {:error, any()}
  def fetch_and_normalise_provider_events(
        %CalendarIntegrationSchema{provider: "exchange"} = integration,
        range_start,
        range_end
      ) do
    fetch_exchange_items(integration, range_start, range_end)
  end

  def fetch_and_normalise_provider_events(
        %CalendarIntegrationSchema{} = integration,
        range_start,
        range_end
      ) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      representation = adapter_client.provider_module.list_events_representation()
      opts = [start_time: range_start, end_time: range_end]

      fetch_and_normalise(adapter_client, integration, representation, opts)
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

  @doc """
  Lists an Exchange mailbox's busy intervals over a window, live from the server.

  The counterpart to `fetch_and_normalise_provider_events/3` for this provider,
  and the more important of the two: `GetUserAvailability` is what decides
  availability, and it is the only EWS read that expands a recurring series.
  The item read the other function performs is known to be short — a grommunio
  mailbox answers one `RecurringMaster` for a whole series — so an audit that
  looked only at items would report a diary as free on every occurrence after
  the first.

  Returns intervals in the order the server listed them. They carry no item
  identity, so a caller correlates them by time, never by uid.
  """
  @spec fetch_exchange_busy_intervals(integration(), DateTime.t(), DateTime.t()) ::
          {:ok, [FreeBusy.interval()]} | {:error, term()}
  def fetch_exchange_busy_intervals(
        %CalendarIntegrationSchema{provider: "exchange"} = integration,
        range_start,
        range_end
      ) do
    ExchangeProvider.list_busy_intervals(integration,
      start_time: range_start,
      end_time: range_end
    )
  end

  @doc """
  Plants one calendar item in an Exchange mailbox over EWS.

  The audit's fixture planter, and no longer a side door: it goes through
  `Exchange.Writes`, the same module `Exchange.Provider.create_event/2` writes
  bookings through, so the audit exercises the write path it is auditing rather
  than a private copy of it. What it adds over the provider callback is the
  fixture shapes a booking never needs — an all-day item given `Date` bounds,
  and a recurring series — which is why it takes an `item_spec` directly
  instead of the canonical event data a meeting produces.

  Returns the item id the server assigned, which is what `delete_exchange_item/2`
  takes and what `Exchange.EventNormaliser` writes into `provider_event_id`. EWS
  assigns the iCalendar UID itself, so a caller cannot choose one and must
  correlate by item id.
  """
  @spec seed_exchange_item(integration(), ExchangeWrites.spec()) ::
          {:ok, ExchangeWrites.item_id()} | {:error, term()}
  def seed_exchange_item(
        %CalendarIntegrationSchema{provider: "exchange"} = integration,
        fixture
      ) do
    ExchangeWrites.create_item(exchange_config(integration), fixture)
  end

  @doc """
  Removes an item planted by `seed_exchange_item/2`.

  `HardDelete`, as every EWS delete here is: a fixture moved to Deleted Items
  is still in the mailbox, and the next audit run reading the whole mailbox
  would find the leftovers of every earlier one.
  """
  @spec delete_exchange_item(integration(), ExchangeWrites.item_id()) ::
          :ok | {:error, term()}
  def delete_exchange_item(
        %CalendarIntegrationSchema{provider: "exchange"} = integration,
        item_id
      ) do
    ExchangeWrites.delete_item(exchange_config(integration), item_id)
  end

  @doc """
  Builds an unpersisted `CalendarIntegrationSchema` struct for an ephemeral
  Exchange (EWS) audit target — no database row is created or required.

  The Baikal builder's counterpart, and the same contract: callers pass a plain
  config map and this owns the encryption and virtual-field details.

  `mailbox` is separate from `username` and not optional in practice: an
  on-premises server accepts `DOMAIN\\samaccountname` as a login and
  `GetUserAvailability` cannot address that, so without an address the busy
  read — the one that decides availability — refuses.

  `calendar_list` is left empty on purpose. `Exchange.Provider.item_client_configs/1`
  falls back to the mailbox's default calendar when nothing is selected, which
  is where `seed_exchange_item/2` plants its fixtures and where
  `Exchange.Provider.build_booking_client_config/1` would write a booking.
  """
  @spec build_ephemeral_exchange_integration(%{
          required(:url) => String.t(),
          required(:username) => String.t(),
          required(:password) => String.t(),
          required(:mailbox) => String.t(),
          optional(:verify_ssl) => boolean()
        }) :: CalendarIntegrationSchema.t()
  def build_ephemeral_exchange_integration(
        %{url: url, username: username, password: password, mailbox: mailbox} = config
      ) do
    %CalendarIntegrationSchema{
      id: 0,
      provider: "exchange",
      name: "#{ProviderConfig.display_name(:exchange)} (#{URI.parse(url).host})",
      base_url: url,
      username_encrypted: Encryption.encrypt(username),
      password_encrypted: Encryption.encrypt(password),
      username: username,
      password: password,
      provider_account_email: mailbox,
      # An EWS folder is named by an opaque `FolderId`, never a path.
      calendar_paths: [],
      calendar_list: [],
      # The provider refuses writes, so it has no booking target to name.
      default_booking_calendar_id: nil,
      verify_ssl: Map.get(config, :verify_ssl, true),
      is_active: true,
      needs_reauth: false
    }
  end

  # The live item read, fanned out over the same per-folder clients the sync
  # worker uses so a folder selection is honoured here exactly as it is there.
  # A failing folder fails the whole read rather than shrinking the result: a
  # short list of events is indistinguishable from a quiet calendar, and an
  # audit that silently lost half a mailbox would report passes it did not earn.
  defp fetch_exchange_items(integration, range_start, range_end) do
    integration
    |> ExchangeProvider.item_client_configs()
    |> Enum.reduce_while({:ok, []}, fn client, {:ok, acc} ->
      case fetch_exchange_folder(integration, client, range_start, range_end) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_exchange_folder(integration, client, range_start, range_end) do
    calendar_id = client[:calendar_id]

    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: to_string(calendar_id),
      synced_at: DateTime.utc_now(:microsecond)
    }

    with {:ok, items} <-
           ExchangeProvider.list_calendar_items(client,
             start_time: range_start,
             end_time: range_end,
             calendar_id: calendar_id
           ) do
      ExchangeProvider.normalise_events(items, context)
    end
  end

  # `Exchange.Writes` speaks the transport's config map, not an integration
  # struct, and the conversion lives on the provider because it is the module
  # that knows the credentials are encrypted and that two fields the CalDAV
  # shape has no room for have to be merged back on top.
  defp exchange_config(integration), do: ExchangeProvider.transport_config(integration)

  defp fetch_and_normalise(adapter_client, integration, :raw, opts) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: integration.default_booking_calendar_id || "",
      synced_at: DateTime.utc_now(:microsecond)
    }

    with {:ok, raw_events} <-
           adapter_client.provider_module.list_events(adapter_client.client, opts) do
      adapter_client.provider_module.normalise_events(raw_events, context)
    end
  end

  defp fetch_and_normalise(_adapter_client, integration, :normalised, _opts) do
    {:error, {:no_raw_representation, integration.provider}}
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
