defmodule Tymeslot.Integrations.Video.EventDetails do
  @moduledoc """
  Canonical shape for the calendar/video event payload used during video-room
  provisioning.

  All three provisioning call sites — the dashboard create flow, the dashboard
  edit flow, and the meetings context — produce a `%EventDetails{}` before
  calling into the video provider. This removes the three-shape problem that
  previously forced `GoogleMeetProvider.normalise_attendee/1` to compensate
  for divergent upstream shapes.

  Attendees take the canonical `Tymeslot.Integrations.Calendar.Attendee`
  shape, with the email trimmed and downcased, whichever source they came
  from.
  """

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Meetings.MeetingSchema

  @type t :: %__MODULE__{
          summary: String.t() | nil,
          description: String.t() | nil,
          start_time: DateTime.t() | NaiveDateTime.t() | nil,
          end_time: DateTime.t() | NaiveDateTime.t() | nil,
          attendees: [Attendee.t()]
        }

  defstruct summary: nil, description: nil, start_time: nil, end_time: nil, attendees: []

  @doc """
  Builds an `%EventDetails{}` from the LiveView `creating` assigns map used in
  the dashboard create flow.

  The `creating` map uses atom keys. Attendees are a list of plain email
  strings, each built into an attendee with no name. Empty or
  whitespace-only titles are normalised to `nil`.
  """
  @spec from_creating_form(map()) :: t()
  def from_creating_form(creating) when is_map(creating) do
    %__MODULE__{
      summary: normalise_summary(creating[:title]),
      description: creating[:description] || "",
      start_time: creating[:start_time],
      end_time: creating[:end_time],
      attendees: normalise_attendees(creating[:attendees] || [])
    }
  end

  @doc """
  Builds an `%EventDetails{}` from the calendar-grid event payload used in the
  dashboard edit flow.

  Event maps use atom keys; times are stored as `:start_at` / `:end_at`.
  Attendees are cached attendee maps in any stored shape (read through
  `Attendee.normalise/1`), or plain strings from older cache rows. Empty or
  whitespace-only summaries are normalised to `nil`.
  """
  @spec from_grid_event(map()) :: t()
  def from_grid_event(event) when is_map(event) do
    %__MODULE__{
      summary: normalise_summary(Map.get(event, :summary)),
      description: Map.get(event, :description) || "",
      start_time: Map.get(event, :start_at),
      end_time: Map.get(event, :end_at),
      attendees: normalise_attendees(Map.get(event, :attendees) || [])
    }
  end

  @doc """
  Builds an `%EventDetails{}` from a `Tymeslot.Meetings.MeetingSchema` struct.
  """
  @spec from_meeting(MeetingSchema.t()) :: t()
  def from_meeting(%MeetingSchema{} = meeting) do
    %__MODULE__{
      summary: normalise_summary(meeting.summary || meeting.title),
      description: meeting.description || "",
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      attendees: meeting_attendees(meeting)
    }
  end

  @doc """
  Reads the event a provider is asked to create or move a room for out of the
  provider config.

  Creation attaches the event under `:event_details` (see
  `Tymeslot.Integrations.Video.Rooms.create_meeting_room/2`), while an update
  hands its changes over as the flat `:meeting_topic`, `:meeting_start_time`
  and `:meeting_end_time` keys. The event details win field by field, and a
  field neither source carries stays `nil`: guessing a title or a time here
  would write an event the organiser never booked into their calendar.
  """
  @spec from_provider_config(map()) :: t()
  def from_provider_config(config) when is_map(config) do
    details =
      case Map.get(config, :event_details) do
        %__MODULE__{} = details -> details
        %{} = details -> struct(__MODULE__, details)
        _other -> %__MODULE__{}
      end

    %{
      details
      | summary: details.summary || normalise_summary(Map.get(config, :meeting_topic)),
        start_time: details.start_time || config_time(config, :meeting_start_time),
        end_time: details.end_time || config_time(config, :meeting_end_time)
    }
  end

  # The flat keys arrive as `DateTime`s from `Rooms.update_meeting_room/2`,
  # and as ISO 8601 strings from a config that went through JSON. A string that
  # does not parse is as good as absent.
  defp config_time(config, key) do
    case Map.get(config, key) do
      %DateTime{} = datetime ->
        datetime

      iso8601 when is_binary(iso8601) ->
        case DateTime.from_iso8601(iso8601) do
          {:ok, datetime, _offset} -> datetime
          {:error, _reason} -> nil
        end

      _other ->
        nil
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp normalise_summary(nil), do: nil
  defp normalise_summary(""), do: nil

  defp normalise_summary(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp meeting_attendees(%MeetingSchema{attendee_email: email, attendee_name: name}),
    do: normalise_attendees([%{email: email, display_name: name}])

  # Accepts plain email strings (the creating-form path, and older cache rows)
  # and attendee maps in any shape `Attendee.normalise/1` reads. An attendee
  # without a usable email is dropped.
  defp normalise_attendees(attendees) when is_list(attendees) do
    attendees
    |> Enum.map(&normalise_attendee/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalise_attendees(_other), do: []

  defp normalise_attendee(email) when is_binary(email),
    do: normalise_attendee(%{email: email})

  defp normalise_attendee(%{} = attendee) do
    attendee = Attendee.normalise(attendee)

    case clean_email(attendee.email) do
      nil -> nil
      email -> %{attendee | email: email}
    end
  end

  defp normalise_attendee(_other), do: nil

  defp clean_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean_email(_other), do: nil
end
