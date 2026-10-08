defmodule TymeslotWeb.Test.FixtureTheme.Voice do
  @moduledoc """
  The fixture theme's voice: five of the shared booking lines in its own
  words (the generic heading, the greeting, the instruction, the
  held-request sentence without an organiser name, and the submit button),
  every other line left to the shared wording. It proves a theme's voice
  reaches `BookingText`, `ConfirmationText` and `BookingLabels`, and that a
  line it leaves alone (the request labels, the sentences naming the
  organiser) keeps the shared wording. Its strings live in the test build
  only, which extraction never compiles; a shipped theme's voice is
  extracted into `booking_voice.pot`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.Voice

  @behaviour Voice

  @impl Voice
  def text(:heading, _bindings), do: dpgettext("booking_voice", "fixture", "Book a time")

  def text(:greeting, %{name: name}),
    do: dpgettext("booking_voice", "fixture", "Hello, %{name} here.", name: name)

  def text(:instruction, _bindings),
    do: dpgettext("booking_voice", "fixture", "Choose a meeting to start.")

  def text(:held_message, %{name: name}),
    do: dpgettext("booking_voice", "fixture", "%{name}, your request is in.", name: name)

  def text(:submit, _bindings), do: dpgettext("booking_voice", "fixture", "Book it")
  def text(_key, _bindings), do: nil
end
