defmodule Tymeslot.Integrations.Calendar.Exchange.Provider do
  @moduledoc """
  Read-only Microsoft Exchange calendar provider, speaking EWS.

  Targets **on-premises** Exchange Server (2016, 2019, SE). Exchange Online is
  served by the `:outlook` provider over Microsoft Graph instead, and its EWS
  endpoint is being retired by Microsoft, so this provider must never be
  offered as a route to a Microsoft 365 mailbox.

  ## Why this is its own family

  EWS is neither CalDAV nor OAuth: it is SOAP over HTTPS with credentials, so
  it builds on neither `CaldavCommon` nor `OAuthBase` and implements the
  `Provider` behaviour directly, as `Ics.Provider` does.

  ## Two live reads, with different jobs

  A sync window costs two independent EWS reads, and neither subsumes the
  other. **Neither is a `Provider` callback and neither is named like one**:
  both are called only by `Tymeslot.Workers.SyncExchangeCalendarWorker`, and
  the names say so on purpose (see the next section).

    * `list_busy_intervals/2` asks `GetUserAvailability` when the mailbox is
      busy. It is the source of truth for availability, and its intervals are
      cached as `busy_only` rows.
    * `list_calendar_items/2` asks `FindItem` over a `CalendarView` for the
      ids in range, then one batched `GetItem` for their fields. It answers
      *what* each event is: identity, subject, location, change key, which is
      what the dashboard grid renders, and its items are cached as
      `display_only` rows. `item_client_configs/1` builds the one client per
      selected folder that read fans out over.

  The split exists because the item path cannot see a recurring series. A
  server was observed answering a `CalendarView` with a single
  `RecurringMaster` dated to the first occurrence, and with nothing at all for
  a window covering later ones, so an organiser booked every morning reads as
  free from the second day on. `GetUserAvailability` expands the series
  server-side. It answers no item identity in return — no id, no subject, no
  change key — which is why it cannot simply replace the item path.

  Availability must therefore never be served from the items, and the two
  lists must never be merged: they are different populations, and the item one
  is known to be short.

  `list_calendar_items/2` costs two round trips per window however many events
  fall in it, because `GetItem` accepts every id at once. `FindItem` is used
  purely to enumerate: it cannot return an item's iCalendar `UID` — the
  property is silently dropped rather than faulted — and a cached event needs
  a stable uid.

  ## `list_events/2` reads the cache, never the network

  The `Provider` callback is neither of those reads, and that is the whole
  point of naming them apart. The availability path
  (`Runtime.EventQueries.fetch_events_from_providers/3` →
  `EventsRead.fetch_events_with_fallback/3` → `ProviderAdapter.get_events/3` →
  `list_events/2`) runs on every booking page load, fans out over every client
  the organiser has, and fails closed if any one of them fails. Answering it
  from EWS would put a credentialed SOAP round trip on that page and hand an
  on-premises server's downtime the power to close the organiser's diary. It
  would also serve availability from the item path, which the section above
  says must never happen. `Ics.Provider` documents the same trap and solves it
  the same way.

  So `list_events/2` reads the local event cache the sync worker last wrote,
  under the availability path's own role filter: `display_only` rows are
  excluded, so an Exchange integration serves its `busy_only` intervals and
  never its known-incomplete item rows.

  A client naming no integration is an error rather than an empty list. This
  is the one place this provider deliberately departs from `Ics.Provider`,
  which answers `{:ok, []}`: here `{:ok, []}` would report the mailbox as free
  for the whole window under a success, which is the worst answer this
  provider can give and the same reasoning that makes
  `{:error, :no_mailbox_address}` an error in `list_busy_intervals/2`.

  ## Availability is whole-mailbox

  `GetUserAvailability` addresses a *mailbox*, not a folder, so selecting a
  subset of calendars does not narrow the busy time it reports. This is a real
  behavioural difference from every other provider and belongs in the
  connection UI's copy, not only here. It is also why the operation needs an
  address where the folder-scoped calls need only a login; see `mailbox/1`.

  ## Read-only

  This phase writes nothing. The three write callbacks return
  `{:error, :read_only}` and `build_booking_client_config/1` returns `nil`, so
  an Exchange calendar blocks availability but can never be resolved as a
  booking target.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.Client
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.FolderDiscovery
  alias Tymeslot.Integrations.Calendar.Exchange.FreeBusy
  alias Tymeslot.Integrations.Calendar.Exchange.ItemDiscovery
  alias Tymeslot.Integrations.Calendar.Exchange.Requests
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon

  # EWS is credentialed HTTP against a user-nominated host, which is exactly
  # what the CalDAV connection-test bucket meters. A bucket of its own would
  # split one user's budget across two pools without protecting anything more.
  @connection_test_bucket :caldav

  # The Availability service caps a `GetUserAvailability` `TimeWindow` at its
  # `MaximumQueryIntervalDays` setting and answers anything longer with an
  # error response code rather than truncating it, so one request cannot
  # cover the sync window (`ProviderConfig`, 365 days each way). The default
  # is 42 days; Exchange 2010 and later default to 62 and an operator may set
  # either higher. 42 is the conservative floor every supported version
  # accepts, and asking for the lower bound costs only a few more round trips
  # a cycle, where guessing the higher one fails the whole read on any server
  # left at the default.
  #
  # grommunio, the server this provider was verified live against, enforces
  # no cap at all, which is why a single window-wide request passed every
  # test here and would have been refused by the first real Exchange Server
  # it met.
  @availability_chunk_days 42

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :exchange

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Microsoft Exchange"

  @impl Tymeslot.Integrations.Calendar.Provider
  def connection_test_bucket, do: @connection_test_bucket

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component,
    do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.ExchangeConfig

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        description: "EWS endpoint URL (e.g. https://mail.example.com/EWS/Exchange.asmx)"
      },
      username: %{
        type: :string,
        required: true,
        description: "Exchange username, usually your email address"
      },
      password: %{type: :string, required: true, description: "Exchange password"},
      verify_ssl: %{
        type: :boolean,
        required: false,
        default: true,
        description: "Verify the server's TLS certificate"
      },
      request_timeout: %{
        type: :integer,
        required: false,
        default: 30_000,
        description: "Request timeout in milliseconds"
      }
    }
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    with :ok <-
           ProviderCommon.validate_required_fields(config, [:base_url, :username, :password]) do
      # The shared validator rather than a bespoke one: the endpoint is a URL
      # the account owner typed, so it gets the same HTTPS and private-address
      # posture every other credentialed provider's server URL gets, including
      # the operator's `ALLOW_PRIVATE_IPS_FOR_CALENDAR` opt-out that an
      # on-premises deployment on a private network needs.
      ProviderCommon.validate_url(Map.get(config, :base_url))
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config), do: {:ok, Map.new(config)}

  @impl Tymeslot.Integrations.Calendar.Provider
  def perform_connection_test(config) do
    case find_folder(config) do
      {:ok, _messages} ->
        {:ok, dgettext("dashboard_calendar_providers", "Exchange connection successful")}

      {:error, :not_found} ->
        {:error,
         dgettext(
           "dashboard_calendar_providers",
           "EWS endpoint not found. It usually ends in /EWS/Exchange.asmx."
         )}

      # Everything else goes through the shared vocabulary rather than growing
      # a per-provider sentence for each reason: a rejected credential and an
      # unreachable host mean the same thing here as they do on every other
      # calendar, and only the endpoint's shape is Exchange's own.
      {:error, reason} ->
        {:error, ErrorHandler.sanitize_error_message(reason, :exchange)}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars(client) do
    case Client.call(to_config(client), Requests.find_folder()) do
      {:ok, doc} -> FolderDiscovery.parse_calendars(doc)
      {:error, _reason} = error -> error
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration) do
    integration
    |> to_config()
    |> discover_calendars()
  end

  @doc """
  Builds the single client the availability fan-out reads through.

  One client, not one per selected folder, because this provider's
  `list_events/2` reads the event cache and the cache is keyed by integration:
  a client per folder would issue the same query once per folder and return
  the same rows every time. It is also the honest shape for what the rows
  describe — `GetUserAvailability` answers for a *mailbox*, so the busy time
  cached under this integration is whole-mailbox however many folders the
  owner selected.

  The per-folder fan-out the item read needs lives in `item_client_configs/1`.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  def build_client_configs(integration) do
    [Map.put(to_config(integration), :calendar_integration_id, integration_id(integration))]
  end

  @doc """
  Builds one client per selected calendar folder, for the item read.

  Called only by `Tymeslot.Workers.SyncExchangeCalendarWorker`, which pairs it
  with `list_calendar_items/2`. A selected calendar the discovery named no
  folder id for is dropped rather than carried: a client with no folder id
  does not read nothing, it reads the mailbox's default calendar, so the
  window would be synced twice under two different calendar ids and every
  meeting in it duplicated on the grid.

  Falls back to the mailbox's default calendar when nothing is selected.
  """
  @spec item_client_configs(CalendarIntegrationSchema.t() | map()) :: [map()]
  def item_client_configs(integration) do
    config = to_config(integration)

    case selected_calendar_ids(integration) do
      [] -> [Map.put(config, :calendar_id, :calendar)]
      ids -> Enum.map(ids, &Map.put(config, :calendar_id, &1))
    end
  end

  # A subscription-shaped provider: nil here means
  # `Runtime.ClientManager.booking_client/1` cannot resolve a booking target
  # even if some caller asks it to.
  @impl Tymeslot.Integrations.Calendar.Provider
  def build_booking_client_config(_integration), do: nil

  @doc """
  Lists the integration's cached events for the requested range.

  The availability read, and a **cache** read: it touches no network at all
  (see the moduledoc for why, and `list_calendar_items/2` /
  `list_busy_intervals/2` for the live reads the sync worker uses). Rows are
  filtered exactly as the rest of the availability path filters them —
  `display_only` excluded — and mapped into the plain-map shape `EventsRead`
  consumes.

  `{:error, :no_calendar_integration_id}` when the client names no
  integration, because an empty success here reads as a mailbox with a free
  diary.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(client, opts) do
    from = Keyword.fetch!(opts, :start_time)
    to = Keyword.fetch!(opts, :end_time)

    case integration_id(client) do
      nil ->
        {:error, :no_calendar_integration_id}

      id ->
        events =
          [id]
          |> CalendarEventQueries.list_blocking_for_range(from, to)
          |> Enum.map(&ProviderCalendarEventSchema.to_read_path_map/1)

        {:ok, events}
    end
  end

  # `list_events/2` above answers from the local event cache, whose rows were
  # normalised on the way in, so it hands back finished maps rather than EWS
  # XML. `normalise_events/2` below still parses raw `CalendarItem` elements,
  # because the sync worker feeds it a live `list_raw_events/2` read.
  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events_representation, do: :normalised

  @doc """
  Lists the raw calendar items falling in the requested range.

  A **live** EWS read, called only by
  `Tymeslot.Workers.SyncExchangeCalendarWorker`. Answers the `t:CalendarItem`
  elements of a batched `GetItem`, which `normalise_events/2` turns into
  `CalendarEvent` structs cached as `display_only` rows. This is the dashboard
  grid's read; availability comes from `list_busy_intervals/2`, and the two
  must not be conflated (see the moduledoc).

  Deliberately not called `list_events/2`: that name belongs to the callback
  the availability path reaches for, and answering that path from here is the
  bug this split exists to prevent.

  A range holding no items skips the batch entirely: `GetItem` requires at
  least one `t:ItemId`, so an empty batch would be answered with a schema
  fault rather than an empty list.
  """
  @spec list_calendar_items(map() | CalendarIntegrationSchema.t(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def list_calendar_items(client, opts) do
    config = to_config(client)
    folder = Keyword.get(opts, :calendar_id) || Map.get(config, :calendar_id) || :calendar
    from = Keyword.fetch!(opts, :start_time)
    to = Keyword.fetch!(opts, :end_time)

    with {:ok, doc} <- Client.call(config, Requests.find_item(folder, from, to)),
         {:ok, ids} <- ItemDiscovery.item_ids(doc) do
      fetch_items(config, ids)
    end
  end

  @doc """
  Lists the mailbox's busy intervals over the requested range.

  A **live** EWS read, called only by
  `Tymeslot.Workers.SyncExchangeCalendarWorker`, whose intervals are cached as
  the `busy_only` rows `list_events/2` then serves. It is the source of truth
  for availability, and the only read that sees every occurrence
  of a recurring series. It answers plain maps carrying bounds and a busy
  type, never `CalendarEvent` structs: `GetUserAvailability` returns no item
  identity at all, so the intervals cannot be correlated back to the meetings
  that produced them.

  `{:error, :no_mailbox_address}` when the integration names no address the
  operation can be addressed to. Answering `{:ok, []}` there would report the
  mailbox as free for the whole window under a success, which is the worst
  answer this provider can give and the one failure it must never degrade
  into; the same reasoning is why an unreadable response is an error inside
  `Exchange.FreeBusy` rather than an empty list.

  ## The window is read in slices

  One request cannot carry the sync window: the Availability service refuses a
  `TimeWindow` longer than `@availability_chunk_days` (see the attribute for
  the limit and why it is set where it is). The requested range is therefore
  sliced into consecutive requests that tile it exactly, from the caller's
  start to the caller's end, and their intervals are concatenated in order.
  The window a caller asks for is still the window read, so a caller pairing
  these bounds with a cache query over the same bounds stays consistent.

  The first slice that fails ends the read with its own error term, exactly as
  the single request it replaced did. A partial answer is never returned: half
  a mailbox's busy time is a diary that reads as free for the rest of the
  year, which is the failure this provider is built around.

  Intervals are handed back as the server sent them, with no merging across
  slice boundaries. A busy period spanning one is clipped by the server to
  each side, so it arrives as two adjacent intervals, and two adjacent rows
  block precisely what one row spanning both would: nothing downstream reasons
  about an interval's identity, or about how many of them cover a stretch. An
  exact duplicate, were a server to answer one unclipped on both sides, is
  collapsed on the way into the cache, since `IntervalNormaliser` derives the
  uid from the bounds and the busy type and
  `ProviderCalendarEventQueries.upsert_batch/1` keeps one entry per uid.
  """
  @spec list_busy_intervals(map() | CalendarIntegrationSchema.t(), keyword()) ::
          {:ok, [FreeBusy.interval()]} | {:error, term()}
  def list_busy_intervals(client, opts) do
    config = to_config(client)
    from = Keyword.fetch!(opts, :start_time)
    to = Keyword.fetch!(opts, :end_time)

    with {:ok, address} <- mailbox(config) do
      fetch_busy_intervals(config, address, availability_slices(from, to))
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_items, context) do
    EventNormaliser.normalise_events(raw_items, context)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(client) do
    case find_folder(client) do
      {:ok, _messages} -> {:ok, %{status: :ok}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(_client, _event_data), do: {:error, :read_only}

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(_client, _uid, _event_data), do: {:error, :read_only}

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(_client, _uid, _opts \\ []), do: {:error, :read_only}

  @doc """
  Builds the transport config an EWS call is issued with.

  Public for `Calendar.Diagnostics` alone, which reaches `Exchange.Seeding`
  with it to plant and remove audit fixtures. It is the same conversion every
  read in this module performs, and sharing it is the point: a second one would
  be a second place to remember that the credentials arrive encrypted, and that
  `verify_ssl` and `provider_account_email` have to be merged back on top of a
  provider config shaped for the CalDAV family.
  """
  @spec transport_config(CalendarIntegrationSchema.t() | map()) :: map()
  def transport_config(integration), do: to_config(integration)

  # --- Private ---

  # The reachability probe both connection callbacks run. It reads the
  # response code rather than stopping at the HTTP status, because EWS states
  # a refusal in the body: a `FindFolder` the account may not read is answered
  # with a well-formed 200 whose message says `ErrorAccessDenied`. Reporting
  # that as a working connection tells the account owner the setup succeeded
  # and leaves discovery and every sync afterwards to fail without explanation.
  #
  # The messages themselves are discarded here; the folders they carry are
  # `discover_calendars/1`'s business, and it applies the same guard through
  # `FolderDiscovery.parse_calendars/1`.
  defp find_folder(client) do
    with {:ok, doc} <- Client.call(to_config(client), Requests.find_folder()) do
      Soap.require_success(doc, "FindFolderResponseMessage")
    end
  end

  # `reduce_while` rather than a `map` and a `find`: the halt is the point.
  # A slice that fails ends the read where it failed, so a refused window is
  # never answered as an unusually quiet one, and the slices past it are not
  # even requested.
  defp fetch_busy_intervals(config, address, slices) do
    Enum.reduce_while(slices, {:ok, []}, fn {from, to}, {:ok, acc} ->
      case fetch_busy_slice(config, address, from, to) do
        {:ok, intervals} -> {:cont, {:ok, acc ++ intervals}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_busy_slice(config, address, from, to) do
    with {:ok, doc} <- Client.call(config, Requests.get_user_availability(address, from, to)) do
      FreeBusy.parse_intervals(doc)
    end
  end

  # Half-open slices: each one ends where the next begins, so the set tiles
  # the caller's range exactly, and no stretch of it is asked for twice.
  #
  # A range that is empty or inverted is handed on as the single request it
  # has always been rather than silently answered `{:ok, []}`. Nothing here
  # asks for one, and a success carrying no intervals is the answer this
  # provider must never invent; let the server say what it makes of it.
  defp availability_slices(from, to) do
    if DateTime.compare(from, to) == :lt do
      from
      |> Stream.iterate(&DateTime.add(&1, @availability_chunk_days, :day))
      |> Stream.take_while(&(DateTime.compare(&1, to) == :lt))
      |> Enum.map(&{&1, slice_end(&1, to)})
    else
      [{from, to}]
    end
  end

  defp slice_end(from, to) do
    Enum.min([DateTime.add(from, @availability_chunk_days, :day), to], DateTime)
  end

  defp fetch_items(_config, []), do: {:ok, []}

  defp fetch_items(config, ids) do
    with {:ok, doc} <- Client.call(config, Requests.get_item(ids)),
         :ok <- EventNormaliser.require_readable_batch(doc) do
      {:ok, EventNormaliser.parse_items(doc)}
    end
  end

  # `GetUserAvailability` names a mailbox, so it needs an address where every
  # other operation needs only a credential. The two are not the same thing:
  # an on-premises server accepts `DOMAIN\samaccountname` as a login, and that
  # is not addressable. `provider_account_email` is the canonical column for
  # the account's own address; the username stands in only when it is itself
  # an address, and nothing stands in when neither is.
  defp mailbox(config) do
    case resolve_mailbox(config) do
      nil -> {:error, :no_mailbox_address}
      address -> {:ok, address}
    end
  end

  defp resolve_mailbox(%{provider_account_email: email}) when is_binary(email) and email != "",
    do: email

  defp resolve_mailbox(%{username: username}), do: address_or_nil(username)
  defp resolve_mailbox(_config), do: nil

  defp address_or_nil(username) when is_binary(username) do
    if String.contains?(username, "@"), do: username, else: nil
  end

  defp address_or_nil(_username), do: nil

  # The availability client carries the integration it caches under; the
  # diagnostic paths hand the persisted struct over directly. Anything else
  # names no integration, and `list_events/2` refuses rather than answering an
  # empty diary.
  defp integration_id(%CalendarIntegrationSchema{id: id}), do: id
  defp integration_id(config) when is_map(config), do: Map.get(config, :calendar_integration_id)
  defp integration_id(_client), do: nil

  defp selected_calendar_ids(integration) do
    integration
    |> Map.get(:calendar_list, [])
    |> Enum.filter(& &1.selected)
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  # Credentials live encrypted on the schema; `decrypt_credentials/1` populates
  # the virtual fields that `to_provider_config/1` then reads. Reading
  # `integration.username` directly would yield nil on a freshly loaded row, so
  # both steps are required and neither is optional.
  #
  # Two fields are merged back on top because `to_provider_config/1` is shaped
  # for the CalDAV family and deliberately carries neither: `verify_ssl`, which
  # an on-premises server with a self-signed certificate needs, and
  # `provider_account_email`, without which the availability read has no
  # mailbox to address. It is stored in plaintext, so it survives the
  # conversion untouched.
  defp to_config(%CalendarIntegrationSchema{} = integration) do
    integration
    |> CalendarIntegrationSchema.decrypt_credentials()
    |> CalendarIntegrationSchema.to_provider_config()
    |> Map.merge(%{
      verify_ssl: integration.verify_ssl,
      provider_account_email: integration.provider_account_email
    })
  end

  # Already-decrypted plain maps (the connection-test and discovery paths build
  # one from form input before any row exists, and `build_client_configs/1`
  # answers them) pass straight through.
  defp to_config(config) when is_map(config), do: config
end
