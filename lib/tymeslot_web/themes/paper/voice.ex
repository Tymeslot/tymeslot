defmodule TymeslotWeb.Themes.Paper.Voice do
  @moduledoc """
  Paper's voice: neutral. Plain, short and invisible: it never talks about
  itself or the organiser's personality. Imperative labels, no exclamation
  marks, no greetings, numbers before words (the persona sheet's brief).

  It words the overview's heading and instruction, leaves the greeting out
  (an empty line, which the overview does not render), names the submit
  button and says plainly that a time was taken. Every other shared line
  keeps the shared wording, and the organiser's own wording still wins over
  all of it. Paper's own lines (its pickers' prompt, an empty week, the
  confirmation's headline) are in its components, in the same
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

  def text(:slot_taken, _bindings),
    do: dpgettext("booking_voice", "paper", "That time was just booked. Choose another.")

  def text(_key, _bindings), do: nil
end
