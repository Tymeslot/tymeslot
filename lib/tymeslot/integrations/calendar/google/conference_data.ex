defmodule Tymeslot.Integrations.Calendar.Google.ConferenceData do
  @moduledoc """
  Builds and interprets the Google Calendar `conferenceData.createRequest`
  payload for inline Google Meet provisioning.

  Keeping this knowledge here (alongside `EventMapper`, which serialises the
  payload to Google's wire format) ensures that no Google-specific shape
  knowledge leaks into the web or orchestration layers.
  """

  alias Tymeslot.Clock

  @doc """
  Returns the `conference_data` map that should be attached to an event's
  internal representation before it is serialised by `EventMapper.format_event_data/1`.

  The `requestId` is randomly generated on every call to satisfy Google's
  idempotency requirements.
  """
  @spec create_request() :: map()
  def create_request, do: create_request(generate_request_id())

  # A booking's request is told apart from a conference added any other way
  # (`booking_conference?/1`), so a conference Tymeslot asked for can be taken
  # off again without touching one the organiser added in Google Calendar.
  @booking_request_prefix "tymeslot-booking-"

  @doc """
  `create_request/0` for a booking's calendar event, with a `requestId` that
  `booking_conference?/1` recognises and that records when it was made
  (`booking_requested_at/1`).
  """
  @spec booking_create_request() :: map()
  def booking_create_request do
    requested_at = DateTime.to_unix(Clock.utc_now())
    create_request("#{@booking_request_prefix}#{requested_at}-#{generate_request_id()}")
  end

  @doc """
  When a raw Google event's conference was asked for by a booking
  (`booking_create_request/0`), or `nil` for any other conference, and for a
  request id that records no time.
  """
  @spec booking_requested_at(map()) :: DateTime.t() | nil
  def booking_requested_at(%{
        "conferenceData" => %{"createRequest" => %{"requestId" => @booking_request_prefix <> id}}
      }) do
    with [seconds, _random] <- String.split(id, "-", parts: 2),
         {unix, ""} <- Integer.parse(seconds),
         {:ok, requested_at} <- DateTime.from_unix(unix) do
      requested_at
    else
      _other -> nil
    end
  end

  def booking_requested_at(_event), do: nil

  @doc """
  Whether a raw Google event's conference is one a booking asked for
  (`booking_create_request/0`).
  """
  @spec booking_conference?(map()) :: boolean()
  def booking_conference?(%{"conferenceData" => %{"createRequest" => %{"requestId" => id}}})
      when is_binary(id),
      do: String.starts_with?(id, @booking_request_prefix)

  def booking_conference?(_event), do: false

  defp create_request(request_id) do
    %{
      createRequest: %{
        requestId: request_id,
        conferenceSolutionKey: %{type: "hangoutsMeet"}
      }
    }
  end

  @doc """
  The `conference_data` value that takes an event's conference off it on an
  update: the event is written with `conferenceDataVersion=1` and no
  `conferenceData`, which Google's full-replace `events.update` reads as none.
  """
  @spec remove() :: :remove
  def remove, do: :remove

  @doc """
  `raw_event`, a cached raw Google event, as a write carrying the
  `conference_data` change leaves it: without a conference after `remove/0`,
  and carrying the request after a `createRequest`, so `booking_conference?/1`
  and `meet_status/1` read the cached copy as Google now holds the event,
  before a sync brings back the conference Google makes for it.
  """
  @spec put_on_event(map(), :remove | map()) :: map()
  def put_on_event(raw_event, :remove), do: Map.delete(raw_event, "conferenceData")

  def put_on_event(raw_event, %{createRequest: request}),
    do: Map.put(raw_event, "conferenceData", %{"createRequest" => stringify_keys(request)})

  @doc """
  Extracts the Google Meet URL from a raw Google Calendar event, the video
  entry point of its `conferenceData`. Returns `nil` when it has none, which
  includes a conference Google is still creating.
  """
  @spec meet_url_from_google_event(map()) :: String.t() | nil
  def meet_url_from_google_event(%{"conferenceData" => %{"entryPoints" => entry_points}})
      when is_list(entry_points) do
    case Enum.find(entry_points, &(&1["entryPointType"] == "video")) do
      %{"uri" => uri} when is_binary(uri) and uri != "" -> uri
      _other -> nil
    end
  end

  def meet_url_from_google_event(_event), do: nil

  @doc """
  Where a raw Google event's Meet stands: `{:ok, url}` once Google has made
  it, `:pending` while a request for one is still being worked on, `:failed`
  when Google failed the request, and `:none` for an event that has none and
  asked for none.
  """
  @spec meet_status(map()) :: {:ok, String.t()} | :pending | :failed | :none
  def meet_status(event) do
    case {meet_url_from_google_event(event), get_in(event, ["conferenceData", "createRequest"])} do
      {url, _request} when is_binary(url) -> {:ok, url}
      {nil, %{"status" => %{"statusCode" => "failure"}}} -> :failed
      {nil, %{}} -> :pending
      {nil, _no_request} -> :none
    end
  end

  @doc """
  Extracts the Google Meet URL from the converted-event map returned by
  `Google.Provider.convert_event/1`.

  Returns `nil` when the event carries no Meet link.
  """
  # Converted events carry atom keys; raw provider payloads that reach here
  # unconverted carry string keys. This function is the single place that
  # answers "which key type?", so callers read one way.
  @spec meet_url_from_event(map()) :: String.t() | nil
  def meet_url_from_event(%{meet_url: meet_url}) when is_binary(meet_url), do: meet_url
  def meet_url_from_event(%{"meet_url" => meet_url}) when is_binary(meet_url), do: meet_url
  def meet_url_from_event(_other), do: nil

  # ── Private ───────────────────────────────────────────────────────────────

  defp generate_request_id, do: Base.encode16(:crypto.strong_rand_bytes(8))

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(value), do: value
end
