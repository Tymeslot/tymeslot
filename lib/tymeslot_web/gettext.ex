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
  through to `handle_missing_translation/5` (and its plural sibling). We
  intercept that path, resolve the *real English* string via `lgettext("en",
  …)`, and hand it to `TymeslotWeb.Gettext.Pseudo` to accent/bracket/pad. Every
  other locale delegates to `super/…`, so real translations are unaffected.
  Resolving English first means key-based catalogs (the booking domain) pseudo
  the visible English text rather than the developer key.
  """
  use Gettext.Backend, otp_app: :tymeslot

  alias Tymeslot.Locales
  alias TymeslotWeb.Gettext.Pseudo

  @impl Gettext.Backend
  def handle_missing_translation("pseudo" = locale, domain, msgctxt, msgid, bindings) do
    if Locales.pseudo_enabled?() do
      {_status, english} = lgettext("en", domain, msgctxt, msgid, bindings)
      {:default, Pseudo.transform(english)}
    else
      super(locale, domain, msgctxt, msgid, bindings)
    end
  end

  def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
    super(locale, domain, msgctxt, msgid, bindings)
  end

  @impl Gettext.Backend
  def handle_missing_plural_translation(
        "pseudo" = locale,
        domain,
        msgctxt,
        msgid,
        msgid_plural,
        n,
        bindings
      ) do
    if Locales.pseudo_enabled?() do
      {_status, english} = lngettext("en", domain, msgctxt, msgid, msgid_plural, n, bindings)
      {:default, Pseudo.transform(english)}
    else
      super(locale, domain, msgctxt, msgid, msgid_plural, n, bindings)
    end
  end

  def handle_missing_plural_translation(locale, domain, msgctxt, msgid, msgid_plural, n, bindings) do
    super(locale, domain, msgctxt, msgid, msgid_plural, n, bindings)
  end
end
