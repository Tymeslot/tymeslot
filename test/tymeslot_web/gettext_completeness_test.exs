defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Enforces that every gettext domain is fully translated into every supported locale.

  See `Tymeslot.GettextCompletenessCase` for the gates this runs and the rationale
  behind each.

  `booking_voice` holds the themes' own wording of the shared booking lines, and
  no shipped theme has a voice yet, so its template is a header only.
  """
  use Tymeslot.GettextCompletenessCase,
    gettext_path: Path.expand("../../priv/gettext", __DIR__),
    empty_domains: ~w(booking_voice),
    async: true

  @moduletag :utils
end
