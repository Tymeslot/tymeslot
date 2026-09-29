defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Enforces that every gettext domain is fully translated into every supported locale.

  See `Tymeslot.GettextCompletenessCase` for the gates this runs and the rationale
  behind each.
  """
  use Tymeslot.GettextCompletenessCase,
    gettext_path: Path.expand("../../priv/gettext", __DIR__),
    async: true

  @moduletag :utils
end
