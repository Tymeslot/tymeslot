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

      case AnalyticsLimiter.check(visitor_hash) do
        {:deny, _limit} -> {:ok, :filtered_rate_limit}
        {:allow, _count} -> do_insert(input, visitor_hash)
      end
    end
  end

  @spec count_visits(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_visits(user_id, from, to), to: EventQueries

  @spec count_unique_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_unique_visitors(user_id, from, to), to: EventQueries

  @spec top_sources(integer(), DateTime.t(), DateTime.t()) :: [map()]
  defdelegate top_sources(user_id, from, to), to: EventQueries

  @spec visits_by_day(integer(), DateTime.t(), DateTime.t()) :: [map()]
  defdelegate visits_by_day(user_id, from, to), to: EventQueries

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
