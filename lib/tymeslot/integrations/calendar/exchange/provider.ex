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

  ## Two reads, with different jobs

  A sync window costs two independent reads, and neither subsumes the other.

    * `list_busy_intervals/2` asks `GetUserAvailability` when the mailbox is
      busy. It is the source of truth for availability.
    * `list_events/2` asks `FindItem` over a `CalendarView` for the ids in
      range, then one batched `GetItem` for their fields. It answers *what*
      each event is: identity, subject, location, change key, which is what
      the dashboard grid renders.

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

  `list_events/2` costs two round trips per window however many events fall in
  it, because `GetItem` accepts every id at once. `FindItem` is used purely to
  enumerate: it cannot return an item's iCalendar `UID` — the property is
  silently dropped rather than faulted — and a cached event needs a stable uid.

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

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.Client
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.FolderDiscovery
  alias Tymeslot.Integrations.Calendar.Exchange.FreeBusy
  alias Tymeslot.Integrations.Calendar.Exchange.Requests
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon

  require Logger

  # EWS is credentialed HTTP against a user-nominated host, which is exactly
  # what the CalDAV connection-test bucket meters. A bucket of its own would
  # split one user's budget across two pools without protecting anything more.
  @connection_test_bucket :caldav

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
    case Client.call(to_config(config), Requests.find_folder()) do
      {:ok, _doc} ->
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

  @impl Tymeslot.Integrations.Calendar.Provider
  def build_client_configs(integration) do
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
  Lists the raw calendar items falling in the requested range.

  Answers the `t:CalendarItem` elements of a batched `GetItem`, which
  `normalise_events/2` turns into `CalendarEvent` structs. This is the
  dashboard grid's read; availability comes from `list_busy_intervals/2`, and
  the two must not be conflated (see the moduledoc).

  A range holding no items skips the batch entirely: `GetItem` requires at
  least one `t:ItemId`, so an empty batch would be answered with a schema
  fault rather than an empty list.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(client, opts) do
    config = to_config(client)
    folder = Keyword.get(opts, :calendar_id) || Map.get(config, :calendar_id) || :calendar
    from = Keyword.fetch!(opts, :start_time)
    to = Keyword.fetch!(opts, :end_time)

    with {:ok, doc} <- Client.call(config, Requests.find_item(folder, from, to)),
         {:ok, ids} <- item_ids(doc) do
      fetch_items(config, ids)
    end
  end

  @doc """
  Lists the mailbox's busy intervals over the requested range.

  This is the availability read, and the only one that sees every occurrence
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
  """
  @spec list_busy_intervals(map() | CalendarIntegrationSchema.t(), keyword()) ::
          {:ok, [FreeBusy.interval()]} | {:error, term()}
  def list_busy_intervals(client, opts) do
    config = to_config(client)
    from = Keyword.fetch!(opts, :start_time)
    to = Keyword.fetch!(opts, :end_time)

    with {:ok, address} <- mailbox(config),
         {:ok, doc} <- Client.call(config, Requests.get_user_availability(address, from, to)) do
      FreeBusy.parse_intervals(doc)
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_items, context) do
    EventNormaliser.normalise_events(raw_items, context)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(client) do
    case Client.call(to_config(client), Requests.find_folder()) do
      {:ok, _doc} -> {:ok, %{status: :ok}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(_client, _event_data), do: {:error, :read_only}

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(_client, _uid, _event_data), do: {:error, :read_only}

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(_client, _uid, _opts \\ []), do: {:error, :read_only}

  # --- Private ---

  defp fetch_items(_config, []), do: {:ok, []}

  defp fetch_items(config, ids) do
    with {:ok, doc} <- Client.call(config, Requests.get_item(ids)),
         :ok <- require_readable_batch(doc) do
      {:ok, EventNormaliser.parse_items(doc)}
    end
  end

  # `GetItem` answers one response message per requested id, so the guard
  # `item_ids/1` applies to `FindItem` — fail on the first stated failure — is
  # the wrong shape here, and a partly successful batch is not an anomaly. The
  # ids come from a *separate* round trip, so an item the organiser deleted
  # between the two calls is answered with its own `ErrorItemNotFound`;
  # failing the window over that would break the grid for the calendar every
  # time someone deletes a meeting mid-sync, and permanently for a single item
  # nobody can read.
  #
  # So the readable items are returned and the failed messages are logged
  # under the server's own codes, with one exception: a batch in which *every*
  # message failed is refused, because that is the emptied-calendar case the
  # guard exists for and it is indistinguishable from an empty window
  # otherwise. What this trades away is the partial case — an event denied on
  # its own message disappears from the grid with only a log line to say so.
  # Availability is unaffected either way: it comes from
  # `GetUserAvailability` over the whole mailbox, never from these items.
  defp require_readable_batch(doc) do
    case Soap.response_messages(doc, "GetItemResponseMessage") do
      [] -> {:error, :no_response_messages}
      messages -> classify_batch(messages, Enum.reject(messages, &succeeded?/1))
    end
  end

  defp classify_batch(_messages, []), do: :ok

  defp classify_batch(messages, failed) when length(failed) == length(messages),
    do: {:error, {:response_code, Soap.response_code(hd(failed))}}

  # Only counts and the server's own codes travel: a failed message names no
  # item, and nothing else in the response is safe to log — a subject or a
  # location is mailbox content.
  defp classify_batch(_messages, failed) do
    Logger.warning("Exchange GetItem batch was partly unreadable",
      provider: :exchange,
      failed_item_count: length(failed),
      response_codes: failed |> Soap.response_codes() |> Enum.uniq() |> Enum.join(", ")
    )

    :ok
  end

  # A message stating no code at all reads back as `""`, which is not
  # `"NoError"` and so counts as failed, matching `Soap.require_success/2`.
  defp succeeded?(message), do: Soap.response_code(message) == "NoError"

  # The response code is read before the items are. A `FindItem` message that
  # failed carries no `m:RootFolder`, so walking straight to the ids answers
  # `[]` for a folder that could not be read at all — which the sync layer
  # cannot tell from a genuinely empty window and persists as an emptied
  # calendar.
  defp item_ids(doc) do
    with {:ok, messages} <- Soap.require_success(doc, "FindItemResponseMessage") do
      {:ok, messages |> Enum.flat_map(&ids_in/1) |> Enum.reject(&is_nil/1)}
    end
  end

  defp ids_in(message) do
    message
    |> Soap.xpath(~x"./m:RootFolder/t:Items/t:CalendarItem/t:ItemId"l)
    |> Enum.map(&to_id_pair/1)
  end

  # An id is what makes an item fetchable, so one without it is dropped rather
  # than sent. The change key is not: EWS treats it as optional, and a
  # `GetItem` naming an id alone is a valid request for the current version of
  # that item, which is what a sync wants anyway.
  defp to_id_pair(item_id) do
    case Soap.text(item_id, ~x"./@Id") do
      nil -> nil
      id -> {id, Soap.text(item_id, ~x"./@ChangeKey") || ""}
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
