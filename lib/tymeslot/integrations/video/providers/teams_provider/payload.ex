defmodule Tymeslot.Integrations.Video.Providers.TeamsProvider.Payload do
  @moduledoc """
  Pure request and response helpers for the Microsoft Teams provider.

  A Teams meeting is a Microsoft Graph calendar event with an online meeting
  attached, so every request here is an event write: a new event for a room of
  its own, an online meeting switched on for the booking's own event, or the
  title and times of an existing event moved. None of these functions perform
  I/O; they are the side-effect-free slice of
  `Tymeslot.Integrations.Video.Providers.TeamsProvider`.
  """

  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Video.EventDetails

  @type window :: %{
          subject: String.t() | nil,
          start_time: DateTime.t(),
          end_time: DateTime.t()
        }

  # Used only when a new event has no title of its own: the times, unlike a
  # title, have no safe stand-in (see `event_window/1`).
  @fallback_subject "Scheduled Meeting"

  @doc """
  The title and times the provider's event must carry, read from `config`
  (see `EventDetails.from_provider_config/1`). The title is `nil` when
  `config` gives none: a new event then takes a generic one, and a moved event
  keeps the title it has, as a calendar grid event's room does, whose update
  carries only its times.

  Missing or unreadable times are refused rather than made up. An event
  written at a guessed time sits in the organiser's calendar looking like a
  booking nobody made, and deleting it looks like cancelling one.
  """
  @spec event_window(map()) :: {:ok, window()} | {:error, {:configuration_error, String.t()}}
  def event_window(config) do
    details = EventDetails.from_provider_config(config)

    with {:ok, start_time} <- to_datetime(details.start_time, :start_time),
         {:ok, end_time} <- to_datetime(details.end_time, :end_time) do
      {:ok,
       %{
         subject: details.summary,
         start_time: start_time,
         end_time: end_time
       }}
    end
  end

  @doc """
  The body of a new event that carries the Teams meeting itself, for a room
  that cannot live on the booking's own calendar event.
  """
  @spec new_event(window(), map()) :: map()
  def new_event(window, config) do
    window
    |> Map.update!(:subject, &(&1 || @fallback_subject))
    |> event_fields()
    |> Map.merge(online_meeting(config))
  end

  @doc """
  The body that turns an existing event into a Teams meeting.

  Only the online meeting is asked for: the event belongs to the booking's
  calendar sync, which owns its title, times and attendees.
  """
  @spec online_meeting(map()) :: map()
  def online_meeting(config) do
    # A personal Microsoft account rejects the business provider, and Graph
    # picks the right consumer one when none is named.
    if personal_account?(config),
      do: %{isOnlineMeeting: true},
      else: %{isOnlineMeeting: true, onlineMeetingProvider: "teamsForBusiness"}
  end

  @doc """
  The body that moves an existing event to a booking's new title and times.
  A window with no title leaves the event's title as it is.
  """
  @spec event_fields(window()) :: map()
  def event_fields(%{subject: subject, start_time: start_time, end_time: end_time}) do
    times = %{
      start: %{dateTime: DateTime.to_iso8601(start_time), timeZone: "UTC"},
      end: %{dateTime: DateTime.to_iso8601(end_time), timeZone: "UTC"}
    }

    if subject, do: Map.put(times, :subject, subject), else: times
  end

  @doc """
  The Teams join link on a Graph event, or `nil` when the event has none.
  """
  @spec join_url(map()) :: String.t() | nil
  def join_url(event) when is_map(event),
    do: get_in(event, ["onlineMeeting", "joinUrl"]) || event["onlineMeetingUrl"]

  defp to_datetime(%DateTime{} = datetime, _field),
    do: {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}

  defp to_datetime(_missing, field), do: missing_time(field)

  # Also reached by a date without a time (an all-day calendar grid event) or
  # a naive time, whose zone is unknown: neither can be placed in Graph's UTC
  # window without guessing.
  defp missing_time(field),
    do: {:error, {:configuration_error, "Teams meeting has no exact #{field}"}}

  defp personal_account?(config) do
    tenant_id = Map.get(config, :tenant_id)

    # The consumer tenant, or a tenant not yet known.
    tenant_id == MicrosoftConfig.consumer_tenant_id() or tenant_id == "common" or
      is_nil(tenant_id)
  end
end
