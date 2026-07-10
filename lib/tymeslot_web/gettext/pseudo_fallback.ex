defmodule TymeslotWeb.Gettext.PseudoFallback do
  @moduledoc """
  Shared `handle_missing_translation/5` and `handle_missing_plural_translation/7`
  callbacks that power the dev-only `"pseudo"` locale.

  Every gettext backend in the umbrella renders the `"pseudo"` locale identically,
  so this coverage tool stays effective across every domain regardless of which
  backend extracted it. `use` this module immediately after `use Gettext.Backend`
  so the injected clauses land after the default's `defoverridable` and `super`
  resolves to it.

  The `lgettext/5` and `lngettext/7` calls below are unqualified, so they resolve
  to the *host* backend's own generated functions — each backend only ever
  pseudo-localises the English string it itself owns.
  """

  defmacro __using__(_opts) do
    quote do
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

      def handle_missing_plural_translation(
            locale,
            domain,
            msgctxt,
            msgid,
            msgid_plural,
            n,
            bindings
          ) do
        super(locale, domain, msgctxt, msgid, msgid_plural, n, bindings)
      end
    end
  end
end
