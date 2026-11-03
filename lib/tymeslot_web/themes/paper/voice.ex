defmodule TymeslotWeb.Themes.Paper.Voice do
  @moduledoc """
  Paper's voice: neutral. Plain, short and invisible: it never talks about
  itself or the organiser's personality. Imperative labels, no exclamation
  marks, no greetings, numbers before words (the persona sheet's brief).

  It words the overview's heading and instruction, leaves the greeting out
  (an empty line, which the overview does not render), names the submit
  button for a booking and a reschedule, says plainly that a time was taken,
  heads the day's times and asks for a date, says a request was sent without
  naming the guest, and words a question's empty choice and its
  acknowledgement. Yes and No, the paid and request labels and the "with
  <organiser>" fragment would read the same in Paper's words, so they keep
  the shared wording, and the organiser's own wording still wins over all of
  it. Paper's own lines (its pickers' prompt, an empty week, the
  confirmation's headline and message) are in its components, in the same
  `booking_voice` context.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.Voice

  @behaviour Voice

  @impl Voice
  def text(:heading_named, %{name: name}),
    do: dpgettext("booking_voice", "paper", "Book a meeting with %{name}", name: name)

  def text(:heading, _bindings), do: dpgettext("booking_voice", "paper", "Book a meeting")

  # No greeting. An empty line, not a msgid: there is nothing to translate.
  def text(:greeting, _bindings), do: ""

  def text(:instruction, _bindings),
    do: dpgettext("booking_voice", "paper", "Select a meeting type")

  def text(:submit, _bindings), do: dpgettext("booking_voice", "paper", "Confirm booking")

  def text(:submit_reschedule, _bindings),
    do: dpgettext("booking_voice", "paper", "Reschedule meeting")

  def text(:slot_taken, _bindings),
    do: dpgettext("booking_voice", "paper", "That time was just booked. Choose another.")

  def text(:slot_heading, _bindings), do: dpgettext("booking_voice", "paper", "Available times")

  def text(:slot_prompt, _bindings), do: dpgettext("booking_voice", "paper", "Select a date")

  # Without the guest's name: Paper addresses nobody.
  def text(:held_message_named, %{organizer_name: organizer_name}),
    do:
      dpgettext("booking_voice", "paper", "Your request to %{organizer} has been sent.",
        organizer: organizer_name
      )

  def text(:held_message, _bindings),
    do: dpgettext("booking_voice", "paper", "Your request has been sent.")

  def text(:select_prompt, _bindings), do: dpgettext("booking_voice", "paper", "Select an option")

  def text(:acknowledge, _bindings), do: dpgettext("booking_voice", "paper", "I have read this")

  def text(_key, _bindings), do: nil
end
