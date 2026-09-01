defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider.Payload do
  @moduledoc """
  Pure payload and response helpers for the Zoom provider.

  Resolves the meeting's start/end times from the request config, builds the
  Zoom `POST /meetings` request body, and decodes Zoom's success and error
  responses. None of these functions perform I/O or touch OAuth state — they
  exist as a focused, side-effect-free slice extracted from
  `Tymeslot.Integrations.Video.Providers.ZoomProvider`.
  """

  alias Tymeslot.Infrastructure.Logging.Redactor

  @doc """
  Resolves the `{start_time, end_time}` pair for the meeting from `config`.

  The create flow supplies the booking's real times via an `%EventDetails{}`
  attached under `:event_details`. The reschedule/update flow supplies them
  directly as `:meeting_start_time`/`:meeting_end_time`. Prefer the event
  details, falling back to the flat keys (and finally the defaults in
  `resolve_*_time/1`).
  """
  @spec get_meeting_times(map()) :: {:ok, {DateTime.t(), DateTime.t()}} | {:error, String.t()}
  def get_meeting_times(config) do
    with {:ok, start_time} <- resolve_start_time(config_start_time(config)),
         {:ok, end_time} <- resolve_end_time(config_end_time(config), start_time) do
      {:ok, {start_time, end_time}}
    end
  end

  @doc """
  Builds the Zoom scheduled-meeting (`type: 2`) request payload.
  """
  @spec build_meeting_payload(DateTime.t(), pos_integer(), map()) :: map()
  def build_meeting_payload(start_time, duration_minutes, config) do
    %{
      topic: config_topic(config),
      type: 2,
      start_time: DateTime.to_iso8601(start_time),
      duration: duration_minutes,
      timezone: "UTC",
      settings: %{
        join_before_host: false,
        waiting_room: true,
        mute_upon_entry: true
      }
    }
  end

  @doc """
  Decodes a Zoom meeting-creation response body, requiring `id` and `join_url`.
  """
  @spec parse_meeting_response(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse_meeting_response(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => _id, "join_url" => _url} = meeting} -> {:ok, meeting}
      {:ok, _other} -> {:error, "Zoom response missing id or join_url"}
      {:error, _reason} -> {:error, "Invalid JSON in Zoom response"}
    end
  end

  @doc """
  Formats a Zoom API error response into an `{:error, {:http_error, status,
  message}}` tuple. Tagged with `status` (rather than flattened to prose) so
  `BreakerOutcome` can tell a genuine outage (5xx/429/408) from a request
  problem and let the breaker witness it.
  """
  @spec decode_and_format_error(integer(), binary()) ::
          {:error, {:http_error, integer(), String.t()}}
  def decode_and_format_error(status, body) do
    detail =
      case Jason.decode(body) do
        {:ok, %{"message" => message, "code" => code}} ->
          # Zoom's own message/code are provider-supplied and can echo request
          # fragments (or token prefixes for auth errors), so they are
          # redacted and bounded the same as the undecodable branch below,
          # just to a tighter cap since this is prose, not a raw body.
          Redactor.redact_and_truncate("code #{code} - #{message}", 512)

        _other ->
          # Undecodable body: still bounded and scrubbed before it reaches a log
          # line, so a provider that answers with something unexpected cannot
          # write an unbounded blob (or whatever it happens to contain) to disk.
          Redactor.redact_and_truncate(body)
      end

    {:error, {:http_error, status, "Zoom API error (#{status}): #{detail}"}}
  end

  defp config_start_time(config) do
    case Map.get(config, :event_details) do
      %{start_time: %DateTime{} = start_time} -> start_time
      _other -> Map.get(config, :meeting_start_time)
    end
  end

  defp config_end_time(config) do
    case Map.get(config, :event_details) do
      %{end_time: %DateTime{} = end_time} -> end_time
      _other -> Map.get(config, :meeting_end_time)
    end
  end

  defp config_topic(config) do
    summary =
      case Map.get(config, :event_details) do
        %{summary: summary} when is_binary(summary) and summary != "" -> summary
        _other -> nil
      end

    summary || Map.get(config, :meeting_topic) || "Scheduled Meeting"
  end

  defp resolve_start_time(nil), do: {:ok, DateTime.add(DateTime.utc_now(), 3600, :second)}
  defp resolve_start_time(dt) when is_binary(dt), do: parse_iso8601(dt)
  defp resolve_start_time(%DateTime{} = dt), do: {:ok, dt}

  defp resolve_end_time(nil, start_time), do: {:ok, DateTime.add(start_time, 1800, :second)}
  defp resolve_end_time(dt, _start_time) when is_binary(dt), do: parse_iso8601(dt)
  defp resolve_end_time(%DateTime{} = dt, _start_time), do: {:ok, dt}

  defp parse_iso8601(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, reason} -> {:error, "Invalid datetime: #{inspect(dt)} (#{reason})"}
    end
  end
end
