defmodule TymeslotWeb.Themes.Quill.Voice do
  @moduledoc """
  Quill's voice: polished and calm. Confident, warm and businesslike,
  considered rather than casual, with no exclamation marks (the persona
  sheet's brief).

  So far it words the overview's heading, which for Quill names no one
  (its heading style is `:generic`). Every other shared line keeps the
  shared wording until Quill's own lines land, and the organiser's own
  wording still wins over all of it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.Voice

  @behaviour Voice

  @impl Voice
  def text(:heading, _bindings), do: dpgettext("booking_voice", "quill", "Arrange a meeting")

  def text(_key, _bindings), do: nil
end
