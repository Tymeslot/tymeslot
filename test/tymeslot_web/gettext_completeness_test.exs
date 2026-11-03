defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Enforces that every gettext domain is fully translated into every supported locale.

  See `Tymeslot.GettextCompletenessCase` for the gates this runs and the rationale
  behind each.

  `booking_voice` holds every line a booking theme words in its own voice, one
  context per theme: its wording of the shared booking lines (its `Voice`
  module) and the lines only its own moments say.
  """
  use Tymeslot.GettextCompletenessCase,
    gettext_path: Path.expand("../../priv/gettext", __DIR__),
    async: true

  @moduletag :utils
end
