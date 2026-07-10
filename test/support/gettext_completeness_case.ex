defmodule Tymeslot.GettextCompletenessCase do
  @moduledoc """
  Shared ExUnit case enforcing that every gettext domain is fully translated
  into every supported locale.

  Listing a locale in `config :tymeslot, :locales` is a promise: it appears in the
  language switcher, so every string a user can reach must exist in it. This case is
  what makes that promise checkable, for whichever `priv/gettext` directory the caller
  points it at. Both Core (`TymeslotWeb.GettextCompletenessTest`) and SaaS
  (`TymeslotSaasWeb.GettextCompletenessTest`) `use` this with their own `:gettext_path` —
  the domains under test differ, the rules do not.

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

  ## Usage

      defmodule MyApp.GettextCompletenessTest do
        use Tymeslot.GettextCompletenessCase,
          gettext_path: Path.expand("../../priv/gettext", __DIR__),
          async: true

        @moduletag :utils
      end

  `:moduletag` is deliberately not an option here — it must appear literally in the
  calling module's own body (as above) so `CredoChecks.TestModuleTagRequired` can see it;
  the check inspects a test file's direct AST and cannot look inside a `use` macro.
  """

  defmacro __using__(opts) do
    # `gettext_path` typically reads `Path.expand("../../priv/gettext", __DIR__)` at
    # the call site — `__DIR__` there must resolve to the *caller's* file, not this
    # module's, so the expression arrives unevaluated and is evaluated against
    # `__CALLER__`'s environment rather than read directly off `opts`.
    {gettext_path, _bindings} =
      Code.eval_quoted(Keyword.fetch!(opts, :gettext_path), [], __CALLER__)

    async = Keyword.fetch!(opts, :async)

    # Every extracted domain. Derived from the `.pot` templates (known once
    # `gettext_path` is expanded, at `use` time), so a domain is covered the moment
    # it is first extracted — there is no allowlist to forget to update. Generated
    # here, in plain Elixir, rather than as a calling-module attribute: one test per
    # domain still has to be spliced in via a nested quote (below), since the outer
    # `quote` here cannot itself `unquote/1` a loop variable bound inside it.
    domains =
      gettext_path
      |> Path.join("*.pot")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".pot"))
      |> Enum.sort()

    msgid_consistency_tests =
      for domain <- domains do
        quote do
          test unquote("every locale has the same msgids in #{domain}.po") do
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

    quote do
      use ExUnit.Case, async: unquote(async)

      alias Expo.PO
      alias Tymeslot.Locales

      @gettext_path unquote(gettext_path)
      @domains unquote(domains)

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
            headers =
              locale |> po_path(domain) |> parse!() |> Map.fetch!(:headers) |> Enum.join()

            assert headers =~ "Language: #{locale}",
                   "#{locale}/#{domain}.po is missing its `Language: #{locale}` header"

            assert headers =~ "Plural-Forms:",
                   "#{locale}/#{domain}.po is missing its `Plural-Forms:` header"
          end
        end
      end

      describe "msgid consistency across locales" do
        unquote(msgid_consistency_tests)
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
  end
end
