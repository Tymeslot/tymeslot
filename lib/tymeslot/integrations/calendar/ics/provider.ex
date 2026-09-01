defmodule Tymeslot.Integrations.Calendar.Ics.Provider do
  @moduledoc """
  Read-only calendar provider backed by a published iCalendar feed.

  Subscribes to a URL the user pastes in: Google's "secret address in iCal
  format", Outlook's "publish a calendar" link, an Apple public calendar, a
  room-booking system's export. Its events block availability and appear on
  the dashboard grid; nothing is ever written back. The three write callbacks
  return `{:error, :read_only}` and `build_booking_client_config/1` returns
  `nil`, so a subscription can never be resolved as a booking target.

  ## Where the events come from

  `list_events/2` reads the **local event cache**, not the feed. This is the
  one place this provider deliberately departs from every other one, and it is
  worth being explicit about why.

  The availability path (`Runtime.EventFetcher.fetch_events_from_providers/3`)
  fans out over every client a user has and fails closed if any of them fails:
  one unreadable calendar means no slots are offered at all. A published feed
  has no date-range parameter, so serving that path from the network would
  download an entire calendar on every booking page load, and would hand a
  third party's downtime the power to close the organiser's diary. It would
  also buy almost nothing: publishers regenerate these files on their own
  schedule, so the feed is already minutes to hours stale before we ask for it.

  So the network is touched only by `Tymeslot.Workers.SyncIcsCalendarWorker`,
  on its poll interval, via `Tymeslot.Integrations.Calendar.Ics.Feed`. Freshness
  is bounded by that interval rather than by the request, and a feed that is
  temporarily unreachable leaves the last known events in place instead of
  emptying the diary.

  ## Discovery

  A feed is a single calendar, so `discover_calendars/1` returns one synthetic
  entry flagged `read_only: true`. That flag is what keeps a subscription out
  of every booking-target picker: `Calendar.writable_calendars/1` and
  `Calendar.Domain.Defaults.eligible_for_booking/1` already filter on it for
  read-only CalDAV and Google calendars, and a subscription is simply the case
  where every calendar is read-only.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.Ics.Feed
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon
  alias Tymeslot.Utils.MapKeys

  # The feed is one calendar with no server-side identifier, so every event
  # cached from it is filed under this fixed provider_calendar_id.
  @calendar_id "subscription"
  @calendar_name "Subscribed calendar"

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :ics_url

  # The only provider whose name is prose rather than a brand: "Nextcloud"
  # reads the same in every locale, "Calendar subscription" does not. The
  # provider directory prefers this callback over
  # `ProviderConfig.display_name/1`, so this is the string the picker card and
  # the connected-integration rows actually render.
  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: dgettext("dashboard_calendar_providers", "Calendar subscription")

  # Same reasoning as the video `:custom` bucket: this probes an arbitrary
  # user-supplied host rather than one the operator configured, so it draws
  # from the tightest budget available.
  @impl Tymeslot.Integrations.Calendar.Provider
  def connection_test_bucket, do: :ics_url

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.IcsUrlConfig

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      subscription_url: %{
        type: :string,
        required: true,
        description: "Published iCalendar feed URL"
      }
    }
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    case feed_url(config) do
      url when is_binary(url) and url != "" ->
        url |> Feed.normalise_url() |> ProviderCommon.validate_url()

      _other ->
        {:error, "Missing required fields: subscription_url"}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config) do
    %{
      feed_url: config |> feed_url() |> normalise(),
      calendar_integration_id: MapKeys.get(config, :calendar_integration_id),
      calendar_path: @calendar_id
    }
  end

  @doc """
  Fetches the feed and reports how many events it holds.

  Pure I/O — the caller (`Tymeslot.Integrations.Calendar.Connection`) decides
  whether and to whom the test is rate-limited.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, term()}
  def perform_connection_test(config) do
    case config |> feed_url() |> normalise() |> fetch_feed() do
      {:ok, events} ->
        {:ok, "Subscribed calendar reachable (#{length(events)} events)"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(client) do
    case fetch_feed(client.feed_url) do
      {:ok, events} -> {:ok, %{status: :ok, event_count: length(events)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches and parses the feed behind `url`.

  The one network entry point on this provider, used by the sync worker and
  the connection test. Everything on the read path goes through
  `list_events/2` and the local cache instead.
  """
  @spec fetch_feed(String.t() | nil) :: {:ok, [map()]} | {:error, Feed.error()}
  def fetch_feed(url) when is_binary(url) and url != "", do: Feed.fetch_events(url)
  def fetch_feed(_url), do: {:error, :missing_url}

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars(client) do
    {:ok, [synthetic_calendar(client[:feed_url])]}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration) do
    {:ok, [synthetic_calendar(subscription_url(integration))]}
  end

  @doc """
  Builds the single client config a subscription has.

  Present so a subscription participates in the availability fan-out at all;
  the client it yields reads the event cache rather than the network (see the
  moduledoc).
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  def build_client_configs(integration) do
    [
      %{
        feed_url: subscription_url(integration),
        calendar_integration_id: integration.id,
        calendar_path: @calendar_id
      }
    ]
  end

  # A subscription is never a booking target: nil here means
  # `Runtime.ClientManager.booking_client/1` cannot resolve one even if some
  # caller asks it to.
  @impl Tymeslot.Integrations.Calendar.Provider
  def build_booking_client_config(_integration), do: nil

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(_client, _event_data), do: {:error, :read_only}

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(_client, _uid, _event_data), do: {:error, :read_only}

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(_client, _uid, _opts \\ []), do: {:error, :read_only}

  @doc """
  Lists cached events for the subscription within the requested range.

  Reads the rows `SyncIcsCalendarWorker` last wrote, mapped back to the shape
  the availability path consumes. All-day rows carry `start_date`/`end_date`
  rather than `start_at`/`end_at`, and are returned as the `Date` values the
  conflict checker already accepts from the CalDAV path.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(client, opts) do
    case client[:calendar_integration_id] do
      nil ->
        {:ok, []}

      integration_id ->
        start_time = Keyword.get(opts, :start_time)
        end_time = Keyword.get(opts, :end_time)

        events =
          [integration_id]
          |> ProviderCalendarEventQueries.list_for_range(start_time, end_time)
          |> Enum.map(&cached_event_to_map/1)

        {:ok, events}
    end
  end

  # The cache holds events that were normalised on the way in, so `list_events/2`
  # hands back finished maps rather than feed text. `normalise_events/2` below
  # still parses raw iCalendar, because the sync worker feeds it the feed itself.
  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events_representation, do: :normalised

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_events, context) do
    ICalNormaliser.normalise_events(raw_events, context, :ics_url)
  end

  # --- Private helpers ---

  defp synthetic_calendar(feed_url) do
    %CalendarEntry{
      id: @calendar_id,
      path: @calendar_id,
      name: @calendar_name,
      type: "calendar",
      selected: true,
      # The whole point of the provider: a feed can be read and never written.
      read_only: true,
      primary: false,
      raw: %{"host" => feed_host(feed_url)}
    }
  end

  defp feed_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> nil
    end
  end

  defp feed_host(_url), do: nil

  # Accepts both shapes `validate_config/1` and `new/1` are called with: the
  # atom-keyed map built during connection setup, and the persisted
  # integration struct once credentials have been decrypted.
  defp feed_url(%{subscription_url: url}) when is_binary(url), do: url
  defp feed_url(%{"subscription_url" => url}) when is_binary(url), do: url
  defp feed_url(%{feed_url: url}) when is_binary(url), do: url
  defp feed_url(_config), do: nil

  defp subscription_url(integration) do
    integration |> feed_url() |> normalise()
  end

  defp normalise(nil), do: nil
  defp normalise(url), do: Feed.normalise_url(url)

  defp cached_event_to_map(event) do
    {start_time, end_time} = cached_event_times(event)

    %{
      uid: event.uid,
      summary: event.summary,
      description: event.description,
      location: event.location,
      start_time: start_time,
      end_time: end_time,
      all_day: event.all_day,
      status: event.status,
      transparency: event.transparency,
      recurrence_rule: nil,
      timezone: event.timezone
    }
  end

  # Occurrences were already expanded before they were cached, so the
  # recurrence rule is deliberately dropped: leaving it on would make
  # `EventsRead.expand_event/3` expand every stored occurrence a second time.
  defp cached_event_times(%{all_day: true} = event), do: {event.start_date, event.end_date}
  defp cached_event_times(event), do: {event.start_at, event.end_at}
end
