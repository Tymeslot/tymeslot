defmodule Tymeslot.Integrations.Calendar.Google.ConferenceData do
  @moduledoc """
  Builds and interprets the Google Calendar `conferenceData.createRequest`
  payload for inline Google Meet provisioning.

  Keeping this knowledge here (alongside `EventMapper`, which serialises the
  payload to Google's wire format) ensures that no Google-specific shape
  knowledge leaks into the web or orchestration layers.
  """

  @doc """
  Returns the `conference_data` map that should be attached to an event's
  internal representation before it is serialised by `EventMapper.format_event_data/1`.

  The `requestId` is randomly generated on every call to satisfy Google's
  idempotency requirements.
  """
  @spec create_request() :: map()
  def create_request do
    %{
      createRequest: %{
        requestId: generate_request_id(),
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
end
