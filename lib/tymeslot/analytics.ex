defmodule Tymeslot.Analytics do
  @moduledoc """
  Public API for booking analytics.

  All page-view writes funnel through `log_page_view/1`, which applies
  bot filtering, computes the cookie-less visitor fingerprint, applies
  rate limiting, and persists the event. Reads delegate to
  `EventQueries`.
  """

  alias Tymeslot.Analytics.BotDetector
  alias Tymeslot.Analytics.EventQueries
  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Analytics.Fingerprint
  alias Tymeslot.Analytics.UtmExtractor
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.RateLimiter.Analytics, as: AnalyticsLimiter

  @type input :: %{
          required(:path) => String.t(),
          required(:user_id) => integer() | nil,
          required(:meeting_type_id) => integer() | nil,
          required(:ip) => String.t() | nil,
          required(:user_agent) => String.t() | nil,
          required(:session_id) => String.t() | nil,
          required(:params) => map(),
          required(:referrer) => String.t() | nil
        }

  @type log_result ::
          {:ok, EventSchema.t()}
          | {:ok, :filtered_bot}
          | {:ok, :filtered_rate_limit}
          | {:error, Ecto.Changeset.t()}

  @spec log_page_view(input()) :: log_result()
  def log_page_view(%{user_agent: ua} = input) do
    if BotDetector.bot?(ua) do
      {:ok, :filtered_bot}
    else
      visitor_hash = Fingerprint.hash(input.ip, ua, input.meeting_type_id)

      if is_nil(visitor_hash) do
        {:ok, :filtered_bot}
      else
        with {:allow, _count} <- check_ip_rate(input.ip),
             {:allow, _count} <- AnalyticsLimiter.check(visitor_hash) do
          do_insert(input, visitor_hash)
        else
          {:deny, _count} -> {:ok, :filtered_rate_limit}
        end
      end
    end
  end

  # Secondary per-IP gate: 300 events per minute regardless of fingerprint.
  # Guards against clients that cycle user-agents to defeat fingerprinting.
  @ip_rate_window_ms 60_000
  @ip_rate_limit 300

  defp check_ip_rate(nil), do: {:allow, 0}

  defp check_ip_rate(ip) do
    AnalyticsLimiter.check_ip("analytics:ip:" <> ip, @ip_rate_window_ms, @ip_rate_limit)
  end

  @spec count_visits(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_visits(user_id, from, to), to: EventQueries

  @spec count_unique_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_unique_visitors(user_id, from, to), to: EventQueries

  @spec visits_by_day(integer(), DateTime.t(), DateTime.t()) :: [map()]
  defdelegate visits_by_day(user_id, from, to), to: EventQueries

  @spec count_bookings(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_bookings(user_id, from, to), to: MeetingQueries

  @doc """
  Returns per-source attribution rows for the given organizer and window.

  Each row merges visit counts (with unique-visitor counts) from analytics
  events with booking counts from meetings, joined on `utm_source`. Only
  sources that appear in either dataset are included.

  Shape: `[%{utm_source: String.t(), visits: non_neg_integer(),
             unique_visitors: non_neg_integer(), bookings: non_neg_integer()}]`
  """
  @spec attribution_table(integer(), DateTime.t(), DateTime.t()) :: [
          %{
            utm_source: String.t(),
            visits: non_neg_integer(),
            unique_visitors: non_neg_integer(),
            bookings: non_neg_integer()
          }
        ]
  def attribution_table(user_id, %DateTime{} = from, %DateTime{} = to) do
    visits = EventQueries.top_sources_with_unique(user_id, from, to)
    bookings = MeetingQueries.count_by_utm_source(user_id, from, to)
    bookings_map = Map.new(bookings, &{&1.utm_source, &1.bookings})

    Enum.map(visits, fn row ->
      Map.put(row, :bookings, Map.get(bookings_map, row.utm_source, 0))
    end)
  end

  defp do_insert(input, visitor_hash) do
    utm = UtmExtractor.extract(input.params)

    attrs = %{
      event_type: "booking_page_view",
      path: input.path,
      meeting_type_id: input.meeting_type_id,
      user_id: input.user_id,
      session_id: input.session_id,
      visitor_hash: visitor_hash,
      utm_source: utm.utm_source,
      utm_medium: utm.utm_medium,
      utm_campaign: utm.utm_campaign,
      utm_content: utm.utm_content,
      utm_term: utm.utm_term,
      tracking_params: utm.tracking_params,
      referrer_host: UtmExtractor.referrer_host(input.referrer),
      user_agent_family: BotDetector.ua_family(input.user_agent)
    }

    EventQueries.insert(attrs)
  end
end
