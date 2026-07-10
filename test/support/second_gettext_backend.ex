defmodule TymeslotWeb.SecondGettextBackendForTest do
  @moduledoc """
  A second Gettext backend, used only by
  `TymeslotWeb.Plugs.LocalePlugTest` to prove that the global
  `Gettext.put_locale/1` (one-arity) form reaches *every* backend for the
  current process, not just `TymeslotWeb.Gettext`.

  This stands in for `TymeslotSaasWeb.Gettext`, which Core cannot reference
  (Core has zero knowledge of SaaS — see CLAUDE.md's Core/SaaS boundary
  rules). It reuses Core's own `priv/gettext` directory purely so the
  backend compiles; no domain here is ever looked up for real translations.
  """
  use Gettext.Backend, otp_app: :tymeslot
end
