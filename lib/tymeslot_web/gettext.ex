defmodule TymeslotWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: TymeslotWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.

  ## Pseudo-localisation

  The dev-only `"pseudo"` locale has no `.po` files, so every lookup falls
  through to `handle_missing_translation/5` (and its plural sibling). Those
  callbacks are injected by `TymeslotWeb.Gettext.PseudoFallback`, which any
  backend in the umbrella may share, and which resolves the *real English*
  string via `lgettext("en", …)` and hands it to `TymeslotWeb.Gettext.Pseudo` to
  accent/bracket/pad. Every other locale delegates to `super/…`, so real
  translations are unaffected. Resolving English first means key-based
  catalogs (the booking domain) pseudo the visible English text rather than
  the developer key.
  """
  use Gettext.Backend, otp_app: :tymeslot
  use TymeslotWeb.Gettext.PseudoFallback
end
