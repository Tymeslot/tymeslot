defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Enforces that every gettext domain is fully translated into every supported locale.

  Listing a locale in `config :tymeslot, :locales` is a promise: it appears in the
  language switcher, so every string a user can reach must exist in it. This test is
  what makes that promise checkable. To stage a partially-translated language, leave it
  out of the config until its catalogues are complete — do not weaken this test.

  Four independent gates, all derived from what is actually on disk, so a newly-wrapped
  domain or a newly-added locale is covered without editing this file:

    * **Structure** — every supported locale carries a `.po` for every `.pot` template,
      with valid `Language:` and `Plural-Forms:` headers.
    * **Consistency** — every locale's msgid set matches English exactly. A missing
      translation falls back; a missing *msgid* is drift between source and catalogue.
    * **Completeness** — no empty `msgstr` in any domain, in any locale other than the
      default. The default locale's msgstrs are intentionally empty: gettext falls back
      to the msgid, which is already English.
    * **No fuzzy entries** — gettext *serves* a fuzzy translation rather than falling
      back to the msgid, so a stale fuzzy msgstr ships as though it were correct. After
      `mix gettext.extract --merge`, review each one and clear the flag.

  Parsing goes through `Expo`, not a line scanner, so a corrupt or truncated `.po` fails
  here rather than at compile time.

  Out of scope, deliberately: changelog and blog **content** (`priv/changelog.json`,
  `priv/blog/*.md`) is data, not gettext, and stays untranslated. Only the page chrome
  around it is wrapped, in the `marketing_about` and `marketing_blog` domains, and that
  chrome is covered here like any other domain.

  The `/for` profession pages localise through per-locale content files rather than
  gettext; their completeness is enforced separately, in the SaaS app, by
  `TymeslotSaasWeb.ForLive.ProfessionCompletenessTest`.
  """
  use ExUnit.Case, async: true
  @moduletag :utils

  alias Expo.PO
  alias Tymeslot.Locales

  @gettext_path Path.expand("../../priv/gettext", __DIR__)

  # Every extracted domain. Derived from the `.pot` templates, so a domain is covered
  # the moment it is first extracted — there is no allowlist to forget to update.
  @domains @gettext_path
           |> Path.join("*.pot")
           |> Path.wildcard()
           |> Enum.map(&Path.basename(&1, ".pot"))
           |> Enum.sort()

  describe "structure" do
    test "every supported locale has a .po for every domain" do
      for locale <- Locales.supported_codes() do
        locale_dir = Path.join([@gettext_path, locale, "LC_MESSAGES"])

        assert File.dir?(locale_dir), "Missing LC_MESSAGES directory for locale: #{locale}"

        missing = Enum.reject(@domains, &File.exists?(po_path(locale, &1)))

        assert missing == [],
               "Locale '#{locale}' is missing catalogues: #{Enum.join(missing, ", ")}"
      end
    end

    test "every .po has valid headers" do
      for locale <- Locales.supported_codes(), domain <- @domains do
        headers = locale |> po_path(domain) |> parse!() |> Map.fetch!(:headers) |> Enum.join()

        assert headers =~ "Language: #{locale}",
               "#{locale}/#{domain}.po is missing its `Language: #{locale}` header"

        assert headers =~ "Plural-Forms:",
               "#{locale}/#{domain}.po is missing its `Plural-Forms:` header"
      end
    end
  end

  describe "msgid consistency across locales" do
    for domain <- @domains do
      test "every locale has the same msgids in #{domain}.po" do
        domain = unquote(domain)
        reference = msgids(Locales.default_locale(), domain)

        refute reference == [], "#{domain}.po has no msgids in the default locale"

        for locale <- Locales.supported_codes() -- [Locales.default_locale()] do
          actual = msgids(locale, domain)

          assert reference -- actual == [],
                 """
                 Locale '#{locale}' is missing msgids in #{domain}.po:
                 #{format_list(reference -- actual)}

                 Run `mix gettext.extract --merge` to sync the catalogues.
                 """

          assert actual -- reference == [],
                 """
                 Locale '#{locale}' has msgids not present in the default locale, in #{domain}.po:
                 #{format_list(actual -- reference)}
                 """
        end
      end
    end
  end

  describe "completeness" do
    test "no untranslated entries in any domain, in any non-default locale" do
      gaps =
        for locale <- Locales.supported_codes() -- [Locales.default_locale()],
            domain <- @domains,
            entries = untranslated(locale, domain),
            entries != [],
            do: {locale, domain, entries}

      assert gaps == [], """
      #{Enum.reduce(gaps, 0, fn {_l, _d, e}, acc -> acc + length(e) end)} untranslated entries.

      Every locale in `config :tymeslot, :locales` must be fully translated — it is
      offered in the language switcher, so an empty msgstr ships English to a user who
      asked for another language.

      #{Enum.map_join(gaps, "\n", fn {locale, domain, entries} -> "  #{locale}/#{domain}.po — #{length(entries)} untranslated:\n#{format_list(entries)}" end)}
      """
    end

    test "no fuzzy entries in any locale" do
      fuzzy =
        for locale <- Locales.supported_codes(),
            domain <- @domains,
            entries = fuzzy(locale, domain),
            entries != [],
            do: {locale, domain, entries}

      assert fuzzy == [], """
      Fuzzy entries found. Gettext SERVES a fuzzy translation — it does not fall back to
      the msgid — so these ship stale text as though it were correct.

      `mix gettext.extract --merge` marks an entry fuzzy when a msgid changed and it
      copied the old msgstr across. Correct each translation (or blank the msgstr) and
      delete the `, fuzzy` flag.

      #{Enum.map_join(fuzzy, "\n", fn {locale, domain, entries} -> "  #{locale}/#{domain}.po:\n#{format_list(entries)}" end)}
      """
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp po_path(locale, domain),
    do: Path.join([@gettext_path, locale, "LC_MESSAGES", "#{domain}.po"])

  defp parse!(path) do
    PO.parse_file!(path)
  rescue
    error in PO.SyntaxError ->
      flunk("#{path} is not a valid .po file: #{Exception.message(error)}")
  end

  defp messages(locale, domain) do
    locale
    |> po_path(domain)
    |> parse!()
    |> Map.fetch!(:messages)
    |> Enum.reject(&(text(&1.msgid) == ""))
  end

  defp msgids(locale, domain), do: locale |> messages(domain) |> Enum.map(&text(&1.msgid))

  defp untranslated(locale, domain) do
    locale
    |> messages(domain)
    |> Enum.filter(&empty_translation?/1)
    |> Enum.map(&text(&1.msgid))
  end

  defp fuzzy(locale, domain) do
    locale
    |> messages(domain)
    |> Enum.filter(&("fuzzy" in List.flatten(&1.flags)))
    |> Enum.map(&text(&1.msgid))
  end

  defp empty_translation?(%Expo.Message.Singular{msgstr: msgstr}), do: text(msgstr) == ""

  defp empty_translation?(%Expo.Message.Plural{msgstr: msgstr}),
    do: Enum.any?(msgstr, fn {_index, str} -> text(str) == "" end)

  defp text(iodata), do: IO.iodata_to_binary(iodata)

  defp format_list(msgids) do
    msgids
    |> Enum.sort()
    |> Enum.map_join("\n", &"      - #{inspect(String.slice(&1, 0, 90))}")
  end
end
