defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Enforces that every gettext domain is fully translated into every supported locale.

  See `Tymeslot.GettextCompletenessCase` for the gates this runs and the rationale
  behind each.

  `booking_voice` holds the themes' own wording of the shared booking lines, and
  no shipped theme has a voice yet, so its template is a header only.

  `dashboard_calendar_views` is registered before its strings are extracted (calendar redesign plan 5); its catalogue task removes it from this list.
  """
  use Tymeslot.GettextCompletenessCase,
    gettext_path: Path.expand("../../priv/gettext", __DIR__),
    empty_domains: ~w(booking_voice dashboard_calendar_views),
    async: true

  @moduletag :utils
end
