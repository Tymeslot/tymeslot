defmodule Tymeslot.GettextCompletenessCase do
  @moduledoc """
  Shared ExUnit case enforcing that every gettext domain is fully and safely translated
  into every supported locale.

  Listing a locale in `config :tymeslot, :locales` is a promise: it appears in the
  language switcher, so every string a user can reach must exist in it. This case is
  what makes that promise checkable, for whichever `priv/gettext` directory the caller
  points it at. Each repository `use`s it with its own `:gettext_path`; the domains
  under test differ, the rules do not.

  The gates, all derived from what is actually on disk, so a newly-wrapped domain or a
  newly-added locale is covered without editing this file:

    * **Structure**: every supported locale carries a `.po` for every `.pot` template,
      with valid `Language:` and `Plural-Forms:` headers.
    * **Consistency**: every locale's messages match the `.pot` template exactly,
      English included. CI's `mix gettext.extract --check-up-to-date` compares the
      templates against source; this compares the catalogues against the templates.
      Together they close the chain, so an extract without `--merge` cannot leave a
      new string silently untranslated everywhere.
    * **Source language**: the default locale's msgstrs are all empty. The msgid *is*
      the English copy, so a filled English msgstr is either a redundant duplicate
      that can drift from the source, or a sign the msgid is a key rather than text.
    * **No key-style msgids**: a msgid such as `"meeting_confirmed"` renders verbatim
      wherever a translation is missing, English included. Write the English text.
    * **Completeness**: no empty `msgstr` in any locale other than the default.
    * **No fuzzy entries**: gettext *serves* a fuzzy translation rather than falling
      back to the msgid, so a stale fuzzy msgstr ships as though it were correct.
    * **Placeholders**: a translation carries exactly its msgid's placeholders (a plural
      form may leave some out, and may always use `count`). An unknown `%{name}` raises
      at render time, and only in that locale, so it would otherwise surface as a crash
      in production; a dropped one silently loses the value it carried.
    * **Plural forms**: every plural entry carries exactly as many msgstrs as its
      catalogue's `nplurals`.
    * **Catalogue size**: no domain holds more than `:max_msgids` messages (default
      300). Catalogues are kept small on purpose, so a change to one area of the app
      means reading one small file; a domain past the limit should be split by area.

  Parsing goes through `Expo`, not a line scanner, so a corrupt or truncated `.po` fails
  here rather than at compile time.

  ## Usage

      defmodule MyApp.GettextCompletenessTest do
        use Tymeslot.GettextCompletenessCase,
          gettext_path: Path.expand("../../priv/gettext", __DIR__),
          async: true

        @moduletag :utils
      end

  `:moduletag` is deliberately not an option here: it must appear literally in the
  calling module's own body (as above) so `CredoChecks.TestModuleTagRequired` can see it;
  the check inspects a test file's direct AST and cannot look inside a `use` macro.
  """

  @default_max_msgids 300

  defmacro __using__(opts) do
    # `gettext_path` typically reads `Path.expand("../../priv/gettext", __DIR__)` at
    # the call site; `__DIR__` there must resolve to the *caller's* file, not this
    # module's, so the expression arrives unevaluated and is evaluated against
    # `__CALLER__`'s environment rather than read directly off `opts`.
    {gettext_path, _bindings} =
      Code.eval_quoted(Keyword.fetch!(opts, :gettext_path), [], __CALLER__)

    async = Keyword.fetch!(opts, :async)
    max_msgids = Keyword.get(opts, :max_msgids, @default_max_msgids)

    # Every extracted domain, derived from the `.pot` templates so a domain is covered
    # the moment it is first extracted; there is no allowlist to forget to update.
    # One consistency test per domain is spliced in via a nested quote, since the outer
    # `quote` below cannot itself `unquote/1` a loop variable bound inside it.
    domains =
      gettext_path
      |> Path.join("*.pot")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".pot"))
      |> Enum.sort()

    msgid_consistency_tests =
      for domain <- domains do
        quote do
          test unquote("every locale matches the #{domain}.pot template") do
            domain = unquote(domain)

            refute Catalogue.template_keys(@gettext_path, domain) == [],
                   "#{domain}.pot has no messages"

            for locale <- Locales.supported_codes() do
              {missing, extra} = Catalogue.template_drift(@gettext_path, locale, domain)

              assert missing == [], """
              Locale '#{locale}' is missing messages from #{domain}.pot:
              #{Catalogue.format_list(missing)}

              Run `mix gettext.extract --merge` to sync the catalogues.
              """

              assert extra == [], """
              Locale '#{locale}' has messages not in #{domain}.pot:
              #{Catalogue.format_list(extra)}

              Run `mix gettext.extract --merge` to sync the catalogues.
              """
            end
          end
        end
      end

    quote do
      use ExUnit.Case, async: unquote(async)

      alias Tymeslot.GettextCompletenessCase.Catalogue
      alias Tymeslot.Locales

      @gettext_path unquote(gettext_path)
      @domains unquote(domains)
      @max_msgids unquote(max_msgids)

      describe "structure" do
        test "every supported locale has a .po for every domain" do
          assert Catalogue.missing_catalogues(@gettext_path, @domains) == []
        end

        test "every .po has valid headers" do
          assert Catalogue.header_problems(@gettext_path, @domains) == []
        end

        test "no domain exceeds the catalogue size limit" do
          oversized = Catalogue.oversized(@gettext_path, @domains, @max_msgids)

          assert oversized == [], """
          Domains over the #{@max_msgids}-message limit:
          #{Catalogue.format_list(oversized)}

          Split each one by app area into smaller domains, so a change to one area means
          reading one small catalogue.
          """
        end
      end

      describe "msgid consistency across locales" do
        unquote(msgid_consistency_tests)
      end

      describe "source language" do
        test "the default locale leaves every msgstr empty" do
          filled = Catalogue.filled_source_msgstrs(@gettext_path, @domains)

          assert filled == [], """
          #{length(filled)} filled msgstrs in the default locale. The msgid is the English
          copy; blank these, and change the source string instead if the English is wrong:
          #{Catalogue.format_list(filled)}
          """
        end

        test "no msgid is a key rather than English text" do
          keys = Catalogue.key_style_msgids(@gettext_path, @domains)

          assert keys == [], """
          Key-style msgids render verbatim wherever a translation is missing, English
          included. Use the English text as the msgid:
          #{Catalogue.format_list(keys)}
          """
        end
      end

      describe "completeness" do
        test "no untranslated entries in any domain, in any non-default locale" do
          gaps = Catalogue.untranslated(@gettext_path, @domains)

          assert gaps == [], """
          #{length(gaps)} untranslated entries.

          Every locale in `config :tymeslot, :locales` must be fully translated: it is
          offered in the language switcher, so an empty msgstr ships English to a user who
          asked for another language.

          #{Catalogue.format_list(gaps)}
          """
        end

        test "no fuzzy entries in any locale" do
          fuzzy = Catalogue.fuzzy(@gettext_path, @domains)

          assert fuzzy == [], """
          Fuzzy entries found. Gettext SERVES a fuzzy translation, it does not fall back to
          the msgid, so these ship stale text as though it were correct.

          `mix gettext.extract --merge` marks an entry fuzzy when a msgid changed and it
          copied the old msgstr across. Correct each translation (or blank the msgstr) and
          delete the `, fuzzy` flag.

          #{Catalogue.format_list(fuzzy)}
          """
        end
      end

      describe "translation safety" do
        test "translations carry exactly the placeholders their msgid defines" do
          mismatched = Catalogue.placeholder_mismatches(@gettext_path, @domains)

          assert mismatched == [], """
          Translations whose placeholders differ from their msgid's. An unknown one raises
          at render time, in that locale only; a dropped one loses the value it carried:
          #{Catalogue.format_list(mismatched)}
          """
        end

        test "plural entries carry one msgstr per plural form" do
          mismatched = Catalogue.plural_count_mismatches(@gettext_path, @domains)

          assert mismatched == [], """
          Plural entries whose msgstr count does not match the catalogue's `nplurals`:
          #{Catalogue.format_list(mismatched)}
          """
        end
      end
    end
  end
end
