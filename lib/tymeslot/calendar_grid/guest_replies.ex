defmodule Tymeslot.CalendarGrid.GuestReplies do
  @moduledoc """
  Who an event on the calendar is with, and how each of them has answered.

  A calendar event's people are its attendees, each with the reply their
  calendar last reported (`Attendee.response_status`). A booking's are the
  person who booked it (or a group meeting's participants), who owe no
  answer, then the guests invited to it through Tymeslot, with the answer
  each gave on the RSVP page.

  A reply is `:accepted`, `:declined`, `:tentative` or `:pending`
  (invited, no answer yet), the statuses `GuestStatusPill` shows. `nil` is
  a person with no reply to show: someone who booked, or an attendee whose
  calendar reported none (a missing reply is not a pending one, see
  `Tymeslot.Integrations.Calendar.Attendee`).
  """

  alias Tymeslot.Integrations.Calendar.Attendee

  @type reply :: :accepted | :declined | :tentative | :pending | nil
  @type guest :: %{name: String.t(), reply: reply()}
  @type summary :: %{
          total: pos_integer(),
          accepted: non_neg_integer(),
          declined: non_neg_integer()
        }

  @doc "The people `event` is with, each with their reply, in the event's own order."
  @spec of_event(map()) :: [guest()]
  def of_event(%{kind: :booking} = booking),
    do: booked(booking) ++ Enum.flat_map(Map.get(booking, :guests) || [], &invited/1)

  def of_event(event) do
    event
    |> Map.get(:attendees)
    |> List.wrap()
    |> Enum.map(&Attendee.normalise/1)
    |> Enum.flat_map(&guest(label(&1.display_name, &1.email), reply(&1.response_status)))
  end

  @doc "A calendar's reported reply as a reply (`nil` when it reported none)."
  @spec reply(Attendee.response_status() | nil) :: reply()
  def reply(:needs_action), do: :pending
  def reply(status) when status in [:accepted, :declined, :tentative], do: status
  def reply(nil), do: nil

  @doc """
  How many of `guests` have a reply, and how many of those are going or
  declined; `nil` when nobody has a reply to show.
  """
  @spec summary([guest()]) :: summary() | nil
  def summary(guests) do
    case Enum.reject(guests, &is_nil(&1.reply)) do
      [] ->
        nil

      answered ->
        %{
          total: length(answered),
          accepted: Enum.count(answered, &(&1.reply == :accepted)),
          declined: Enum.count(answered, &(&1.reply == :declined))
        }
    end
  end

  # A group meeting's people are its live participants; a one-to-one
  # booking's is the person who booked it.
  defp booked(%{participants: [_first | _rest] = participants}),
    do: Enum.flat_map(participants, &guest(label(&1.name, &1.email), nil))

  defp booked(booking),
    do: guest(label(Map.get(booking, :attendee_name), Map.get(booking, :attendee_email)), nil)

  defp invited(%{name: name, email: email, status: status}),
    do: guest(label(name, email), status)

  defp guest(nil, _reply), do: []
  defp guest(name, reply), do: [%{name: name, reply: reply}]

  defp label(name, email), do: present(name) || present(email)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
