defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Enforces that every gettext domain is fully translated into every supported locale.

  See `Tymeslot.GettextCompletenessCase` for the full rationale behind the four gates
  this runs (structure, msgid consistency, completeness, no fuzzy entries).

  Out of scope, deliberately: changelog and blog **content** (`priv/changelog.json`,
  `priv/blog/*.md`) is data, not gettext, and stays untranslated. Only the page chrome
  around it is wrapped, in the `marketing_about` and `marketing_blog` domains, and that
  chrome is covered here like any other domain.

  The `/for` profession pages localise through per-locale content files rather than
  gettext; their completeness is enforced separately, in the SaaS app, by
  `TymeslotSaasWeb.ForLive.ProfessionCompletenessTest`.
  """
  use Tymeslot.GettextCompletenessCase,
    gettext_path: Path.expand("../../priv/gettext", __DIR__),
    async: true

  @moduletag :utils
end
