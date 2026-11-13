defmodule Tymeslot.Notifications.BookingDetails do
  @moduledoc """
  What the booker told the organiser, for the chat notifications (Telegram
  and Slack): their notes, phone and company, where the meeting is held when
  that is not a video call, and their answers to the meeting type's questions.

  Every value is the booker's own input, so each is cut to a length that keeps
  the whole message inside the channels' limits (Telegram's 4096 characters a
  message, Slack's 2000 a field and 3000 a section), however much was typed:
  the full text stays in the dashboard. Answers past `@max_answers` are
  counted in `:more_answers` rather than listed. Values come back unescaped;
  each channel escapes for its own markup.

  For a group meeting the caller passes the seat's view
  (`Tymeslot.Meetings.SeatView`), which carries that participant's notes,
  contact details and answers in the meeting's own fields.
  """

  alias Tymeslot.CustomFields.AnswerRenderer

  @max_note_length 500
  @max_contact_length 100
  @max_location_length 200
  @max_label_length 60
  @max_answer_length 150
  @max_answers 10

  @type t :: %{
          note: String.t() | nil,
          phone: String.t() | nil,
          company: String.t() | nil,
          location: String.t() | nil,
          answers: [{String.t(), String.t()}],
          more_answers: non_neg_integer()
        }

  @spec from_meeting(map()) :: t()
  def from_meeting(meeting) do
    location = location(meeting)
    {shown, hidden} = Enum.split(AnswerRenderer.labelled_answers(meeting), @max_answers)

    %{
      note: present(Map.get(meeting, :attendee_message), @max_note_length),
      # A phone meeting held on the booker's own number already names it.
      phone: present(Map.get(meeting, :attendee_phone), @max_contact_length, [location]),
      company: present(Map.get(meeting, :attendee_company), @max_contact_length),
      location: location,
      answers:
        Enum.map(shown, fn {label, value} ->
          {truncate(label, @max_label_length), truncate(value, @max_answer_length)}
        end),
      more_answers: length(hidden)
    }
  end

  # A video meeting's location is its room link, which the channels already
  # offer as a button or link of their own.
  defp location(%{location_kind: :video}), do: nil
  defp location(meeting), do: present(Map.get(meeting, :location), @max_location_length)

  defp present(value, max, already_shown \\ [])

  defp present(value, max, already_shown) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> if trimmed in already_shown, do: nil, else: truncate(trimmed, max)
    end
  end

  defp present(_value, _max, _already_shown), do: nil

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
