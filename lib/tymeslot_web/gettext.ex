defmodule TymeslotWeb.Gettext do
  @moduledoc """
  Core's Gettext backend.

      use Gettext, backend: TymeslotWeb.Gettext

      dgettext("booking", "Confirm your booking")
      dngettext("booking", "1 slot available", "%{count} slots available", count)

  Every call names its domain explicitly: bare `gettext/1` and `ngettext/3`
  target the implicit `default` domain, which has no catalogue, and
  `CredoChecks.GettextDomainBoundary` rejects them along with any domain it does
  not know. Catalogues are split per app area and compiled per locale and
  domain (`split_module_by`), so editing one `.po` recompiles one module.

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.

  ## Pseudo-localisation

  The dev-only `"pseudo"` locale has no `.po` files, so every lookup falls
  through to `handle_missing_translation/5` (and its plural sibling). Those
  callbacks are injected by `TymeslotWeb.Gettext.PseudoFallback`, which every
  backend shares, and which resolves the English string via `lgettext("en", …)`
  (so bindings are interpolated) and hands it to `TymeslotWeb.Gettext.Pseudo`
  to accent/bracket/pad. Every other locale delegates to `super/…`, so real
  translations are unaffected.
  """
  use Gettext.Backend, otp_app: :tymeslot, split_module_by: [:locale, :domain]
  use TymeslotWeb.Gettext.PseudoFallback
end
