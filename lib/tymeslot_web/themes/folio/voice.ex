defmodule TymeslotWeb.Themes.Folio.Voice do
  @moduledoc """
  Folio's voice: personal. First person, warm and unhurried, like the
  organiser's own website: sentences rather than labels, "I" and "you",
  section headings that are phrases, a button that says what happens next,
  and never "slot" or "meeting type" (the persona sheet's brief).

  It words the heading above the meeting types ("Ways to work with me"),
  drops the instruction label (an empty line, which Folio does not render),
  names the two submits and says gently that a time was taken. Every other
  shared line keeps the shared wording, and the organiser's own wording
  still wins over all of it. Folio's own lines (its moments' headings, an
  empty month, the confirmation) are in its components, in the same
  `booking_voice` context.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.Voice

  @behaviour Voice

  @impl Voice
  def text(key, _bindings) when key in [:heading, :heading_named],
    do: dpgettext("booking_voice", "folio", "Ways to work with me")

  # No instruction label. An empty line, not a msgid: nothing to translate.
  def text(:instruction, _bindings), do: ""

  def text(:submit, _bindings), do: dpgettext("booking_voice", "folio", "Book our session")

  def text(:submit_request, _bindings),
    do: dpgettext("booking_voice", "folio", "Request this time")

  def text(:slot_taken, _bindings),
    do:
      dpgettext(
        "booking_voice",
        "folio",
        "Someone took that time a moment ago. Here are the nearest ones."
      )

  def text(_key, _bindings), do: nil
end
