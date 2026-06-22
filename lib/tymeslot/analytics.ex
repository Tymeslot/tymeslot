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
  alias Tymeslot.Analytics.Telemetry
  alias Tymeslot.Analytics.UtmExtractor
  alias Tymeslot.Meetings
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
          | {:ok, :disabled}
          | {:ok, :filtered_bot}
          | {:ok, :filtered_rate_limit}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Whether booking analytics collection is enabled for this installation.

  Gated behind the `:booking_analytics_enabled` config flag, which defaults
  to `false` in Core so self-hosters never collect visitor analytics unless
  they opt in. The managed SaaS overrides it to `true`. Every collection and
  read path consults this predicate — Core checks the flag value, never SaaS
  presence.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:tymeslot, :booking_analytics_enabled, false)

  @spec log_page_view(input()) :: log_result()
  def log_page_view(%{user_agent: ua} = input) do
    result =
      cond do
        not enabled?() -> {:ok, :disabled}
        BotDetector.bot?(ua) -> {:ok, :filtered_bot}
        true -> insert_if_allowed(input, ua)
      end

    # Emit the outcome so otherwise-silent drops are observable — the caller
    # logs this write in a fire-and-forget Task and discards the result.
    Telemetry.emit(outcome_tag(result))
    result
  end

  defp insert_if_allowed(input, ua) do
    visitor_hash = Fingerprint.hash(input.ip, ua, input.session_id)

    with {:allow, _count} <- check_ip_rate(input.ip),
         {:allow, _count} <- AnalyticsLimiter.check(visitor_hash) do
      do_insert(input, visitor_hash)
    else
      {:deny, _count} -> {:ok, :filtered_rate_limit}
    end
  end

  defp outcome_tag({:ok, %EventSchema{}}), do: :ok
  defp outcome_tag({:ok, tag}) when is_atom(tag), do: tag
  defp outcome_tag({:error, _changeset}), do: :error

  # Secondary per-IP gate: 300 events per minute regardless of fingerprint.
  # Guards against clients that cycle user-agents to defeat fingerprinting.
  @ip_rate_window_ms 60_000
  @ip_rate_limit 300

  defp check_ip_rate(nil), do: {:allow, 0}

  defp check_ip_rate(ip) do
    AnalyticsLimiter.check_ip("analytics:ip:" <> ip, @ip_rate_window_ms, @ip_rate_limit)
  end

  @doc """
  Computes the conversion rate as a formatted percentage string.

  `converting_visitors` is counted independently from the `meetings` table as
  the number of distinct `visitor_hash` values on booked meetings. It is NOT
  derived from the `analytics_events` table and is therefore NOT strictly a
  subset of `unique_visitors` (which counts distinct hashes in page-view
  events). The two counts use separate tables, different time windows, and
  different hash salts (rotated daily), so converting visitors can legitimately
  exceed unique visitors in production. The `min/2` cap is a structural guard,
  not a rare edge case.

  Formatted to one decimal place (e.g. `"66.7"`). When `unique_visitors` is
  zero, returns `"0.0"` to avoid a divide-by-zero. The returned string does not
  include the `%` character — callers append it.
  """
  @spec conversion_rate(non_neg_integer(), non_neg_integer()) :: String.t()
  def conversion_rate(_converting_visitors, 0), do: "0.0"

  def conversion_rate(converting_visitors, unique_visitors) do
    rate = min(100.0, converting_visitors / unique_visitors * 100)
    :erlang.float_to_binary(rate, decimals: 1)
  end

  @doc """
  Extracts UTM parameters, custom tracking params, and referrer host from a
  request, returning the canonical attribution map used throughout the
  booking flow.

  `params` is the LiveView URL params map. `referrer` is the raw referrer URL
  string from the HTTP request header (or `nil`).

  The returned map has the shape:
  `%{utm_source, utm_medium, utm_campaign, utm_content, utm_term,
     tracking_params, referrer_host}`

  This is the map assigned to `:tracking` on the socket and later merged
  into meeting params on booking submission.
  """
  @spec extract_attribution(map(), String.t() | nil) :: %{
          utm_source: String.t() | nil,
          utm_medium: String.t() | nil,
          utm_campaign: String.t() | nil,
          utm_content: String.t() | nil,
          utm_term: String.t() | nil,
          tracking_params: map(),
          referrer_host: String.t() | nil
        }
  def extract_attribution(params, referrer) do
    params
    |> UtmExtractor.extract()
    |> Map.put(:referrer_host, UtmExtractor.referrer_host(referrer))
  end

  @spec count_visits(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_visits(user_id, from, to), to: EventQueries

  @spec count_unique_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_unique_visitors(user_id, from, to), to: EventQueries

  @spec visits_by_day(integer(), DateTime.t(), DateTime.t(), String.t()) :: [map()]
  defdelegate visits_by_day(user_id, from, to, time_zone), to: EventQueries

  @spec device_breakdown(integer(), DateTime.t(), DateTime.t()) :: [map()]
  defdelegate device_breakdown(user_id, from, to), to: EventQueries

  @spec count_bookings(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_bookings(user_id, from, to), to: Meetings

  @spec count_converting_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_converting_visitors(user_id, from, to), to: Meetings

  @doc """
  Returns per-source attribution rows for the given organizer and window.

  Each row merges visit counts (with unique-visitor counts) from analytics
  events with booking counts and distinct converting-visitor counts from
  meetings, joined on `utm_source`. Sources present in any dataset are
  included — booking-only sources appear with `visits: 0, unique_visitors: 0`,
  and visit-only sources appear with `bookings: 0, converting_visitors: 0`.

  `converting_visitors` (distinct bookers who carry a `visitor_hash`) is the
  numerator for the per-source conversion rate; `bookings` remains the raw
  volume of meetings from that source.

  Ordering: visits descending, then bookings descending, then utm_source
  ascending for deterministic ties.

  Shape: `[%{utm_source: String.t(), visits: non_neg_integer(),
             unique_visitors: non_neg_integer(), bookings: non_neg_integer(),
             converting_visitors: non_neg_integer()}]`
  """
  @spec attribution_table(integer(), DateTime.t(), DateTime.t()) :: [
          %{
            utm_source: String.t(),
            visits: non_neg_integer(),
            unique_visitors: non_neg_integer(),
            bookings: non_neg_integer(),
            converting_visitors: non_neg_integer()
          }
        ]
  def attribution_table(user_id, %DateTime{} = from, %DateTime{} = to) do
    visits = EventQueries.top_sources_with_unique(user_id, from, to)
    bookings = Meetings.bookings_by_utm_source(user_id, from, to)
    converting = Meetings.converting_visitors_by_utm_source(user_id, from, to)

    visits_map = Map.new(visits, &{&1.utm_source, &1})
    bookings_map = Map.new(bookings, &{&1.utm_source, &1.bookings})
    converting_map = Map.new(converting, &{&1.utm_source, &1.converting_visitors})

    [visits_map, bookings_map, converting_map]
    |> Enum.flat_map(&Map.keys/1)
    |> MapSet.new()
    |> Enum.map(fn source ->
      visit_row = Map.get(visits_map, source, %{visits: 0, unique_visitors: 0})

      %{
        utm_source: source,
        visits: visit_row.visits,
        unique_visitors: visit_row.unique_visitors,
        bookings: Map.get(bookings_map, source, 0),
        converting_visitors: Map.get(converting_map, source, 0)
      }
    end)
    |> Enum.sort_by(&{-&1.visits, -&1.bookings, &1.utm_source})
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
      user_agent_family: BotDetector.ua_family(input.user_agent),
      device_type: BotDetector.device_type(input.user_agent)
    }

    EventQueries.insert(attrs)
  end
end
