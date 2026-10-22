defmodule Tymeslot.Meetings.JoinUrl do
  @moduledoc """
  The video link the organiser joins a meeting with, read off the meeting row.
  Kept apart from `Tymeslot.Meetings.MeetingSchema`, which holds the row's
  shape and its changesets.
  """

  alias Tymeslot.Meetings.MeetingSchema

  @doc """
  The link the organiser joins the video call with: their own (host) room link
  where the provider issued one, else the shared meeting link; `nil` for a
  meeting without video.
  """
  @spec organizer_join_url(MeetingSchema.t()) :: String.t() | nil
  def organizer_join_url(%MeetingSchema{} = meeting),
    do: present_url(meeting.organizer_video_url) || present_url(meeting.meeting_url)

  defp present_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_url(_url), do: nil
end
