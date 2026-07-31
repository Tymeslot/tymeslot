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
