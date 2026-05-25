defmodule Tymeslot.Integrations.Video.EventDetails do
  @moduledoc """
  Canonical shape for the calendar/video event payload used during video-room
  provisioning.

  All three provisioning call sites — the dashboard create flow, the dashboard
  edit flow, and the meetings context — produce a `%EventDetails{}` before
  calling into the video provider. This removes the three-shape problem that
  previously forced `GoogleMeetProvider.normalise_attendee/1` to compensate
  for divergent upstream shapes.
  """

  alias Tymeslot.Meetings.MeetingSchema

  @type attendee :: %{email: String.t(), name: String.t() | nil}
  @type t :: %__MODULE__{
          summary: String.t() | nil,
          description: String.t() | nil,
          start_time: DateTime.t() | NaiveDateTime.t() | nil,
          end_time: DateTime.t() | NaiveDateTime.t() | nil,
          attendees: [attendee()]
        }

  defstruct summary: nil, description: nil, start_time: nil, end_time: nil, attendees: []

  @doc """
  Builds an `%EventDetails{}` from the LiveView `creating` assigns map used in
  the dashboard create flow.

  The `creating` map uses atom keys. Attendees are a list of plain email
  strings; they are normalised to `%{email: _, name: nil}` maps. Empty or
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
  Attendees, when present, are already `%{email: _, name: _}` maps (or plain
  strings from older cache rows). Empty or whitespace-only summaries are
  normalised to `nil`.
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

  # ── Private helpers ───────────────────────────────────────────────────────

  defp normalise_summary(nil), do: nil
  defp normalise_summary(""), do: nil

  defp normalise_summary(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp meeting_attendees(%MeetingSchema{attendee_email: email, attendee_name: name})
       when is_binary(email) and email != "" do
    [%{email: String.downcase(String.trim(email)), name: name}]
  end

  defp meeting_attendees(_meeting), do: []

  # Accepts:
  #   - plain email strings (from the creating-form path, where :attendees is [String.t()])
  #   - %{"email" => _} maps (from legacy callers)
  #   - %{email: _} / %{email: _, name: _} atom-key maps (normalised form)
  defp normalise_attendees(attendees) when is_list(attendees) do
    attendees
    |> Enum.map(&normalise_attendee/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalise_attendees(_other), do: []

  defp normalise_attendee(%{email: email} = a) when is_binary(email) and email != "" do
    %{email: String.downcase(String.trim(email)), name: Map.get(a, :name)}
  end

  defp normalise_attendee(%{"email" => email} = a) when is_binary(email) and email != "" do
    %{email: String.downcase(String.trim(email)), name: a["name"]}
  end

  # accepts legacy bare string emails from EventCreate's creating[:attendees] list
  defp normalise_attendee(email) when is_binary(email) and email != "" do
    %{email: String.downcase(String.trim(email)), name: nil}
  end

  defp normalise_attendee(_other), do: nil
end
