defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Tests to ensure translation completeness across all supported languages.

  Strings are organised into per-area gettext domains (see
  `CredoChecks.GettextDomainBoundary`). Two independent levels of guarantee are
  enforced, so a domain can be wrapped for translation long before it is actually
  translated:

  - **Structure & consistency** (`@content_domains`, derived automatically from
    the `.pot` templates present): every locale must carry the same `.po` files
    with the same msgid set and proper headers. This holds even for domains that
    are not translated yet — a missing translation falls back to English, but a
    missing *msgid* is a real inconsistency. Newly-wrapped domains join this set
    the moment their `.pot` is extracted; no edit here is needed.
  - **No empty translations & size** (`@translated_domains` × `@launched_locales`):
    domains declared complete must stay complete, in every launched locale.

  A domain graduates into `@translated_domains` only once it is fully translated;
  a locale graduates into `@launched_locales` only once every `@translated_domains`
  catalog is complete for it. This is the "never ship on the fallback" gate.

  Deliberately absent from `@translated_domains`: `dashboard`/`emails` (existing
  untranslated strings) and every newly-wrapped authenticated-app domain
  (`dashboard_*`, `auth`, `account`, `onboarding_wizard`, `dashboard_common`) —
  those are wrapped English-only for now and translated in a later phase.
  """
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Themes.Shared.LocaleHandler

  @gettext_path Path.expand("../../priv/gettext", __DIR__)

  # Domains with content in every locale — checked for file presence, header
  # correctness, and msgid-set consistency across locales. Derived from the
  # `.pot` templates so every extracted domain is covered automatically.
  @content_domains @gettext_path
                   |> Path.join("*.pot")
                   |> Path.wildcard()
                   |> Enum.map(&Path.basename(&1, ".pot"))
                   |> Enum.sort()

  # Domains that are fully translated in every launched locale — additionally
  # checked for empty translations and reasonable file size. Graduate a domain
  # in here only when it reaches zero untranslated entries across all locales.
  @translated_domains ~w(booking onboarding common errors embed)

  # Locales that have been launched — every `@translated_domains` catalog is
  # complete for these. The empty-translation and size gates run over this set,
  # so a locale can be launched independently once its in-scope domains are done.
  # Currently equal to the supported set (all translated domains are complete in
  # all locales); trim/extend as new domains are translated locale-by-locale.
  @launched_locales ~w(en de fr uk it)

  @content_files Enum.map(@content_domains, &"#{&1}.po")
  @translated_files Enum.map(@translated_domains, &"#{&1}.po")

  describe "translation structure" do
    test "all supported locales have all content translation files" do
      for locale <- LocaleHandler.supported_locales() do
        locale_dir = Path.join([@gettext_path, locale, "LC_MESSAGES"])

        assert File.dir?(locale_dir),
               "Missing LC_MESSAGES directory for locale: #{locale}"

        for po_file <- @content_files do
          po_path = Path.join(locale_dir, po_file)

          assert File.exists?(po_path),
                 "Missing translation file: #{locale}/LC_MESSAGES/#{po_file}"
        end
      end
    end

    test "all .po files have proper headers" do
      for_each_locale_and_file(@content_files, &assert_proper_headers/2)
    end
  end

  describe "msgid consistency across locales" do
    for domain <- @content_domains do
      test "all locales have the same msgids in #{domain}.po" do
        assert_msgids_consistency("#{unquote(domain)}.po")
      end
    end
  end

  describe "translation completeness" do
    test "no empty translations (msgstr) in fully-translated domains" do
      for locale <- @launched_locales, po_file <- @translated_files do
        assert_no_empty_translations(locale, po_file)
      end
    end

    test "translation file sizes are reasonable" do
      # English is the reference - other translations shouldn't be much smaller
      # (which might indicate missing content)
      reference_sizes = get_file_sizes("en")

      launched_locales = @launched_locales -- ["en"]

      for locale <- launched_locales, po_file <- @translated_files do
        po_path = Path.join([@gettext_path, locale, "LC_MESSAGES", po_file])
        file_size = File.stat!(po_path).size
        reference_size = reference_sizes[po_file]

        # Allow translations to be 50% to 150% of English size
        # (different languages have different lengths)
        min_size = div(reference_size, 2)
        max_size = reference_size * 2

        assert file_size >= min_size,
               """
               #{locale}/#{po_file} is suspiciously small (#{file_size} bytes).
               English version is #{reference_size} bytes.
               This might indicate missing translations.
               """

        assert file_size <= max_size,
               """
               #{locale}/#{po_file} is suspiciously large (#{file_size} bytes).
               English version is #{reference_size} bytes.
               """
      end
    end
  end

  # Helper functions

  defp assert_msgids_consistency(po_file) do
    msgids_by_locale = get_msgids_by_locale(po_file)

    # Get English as reference (should be complete)
    reference_msgids = msgids_by_locale["en"]
    assert reference_msgids != [], "English #{po_file} has no msgids"

    # Check all other locales have the same msgids
    for {locale, msgids} <- msgids_by_locale do
      missing_in_locale = reference_msgids -- msgids
      extra_in_locale = msgids -- reference_msgids

      assert missing_in_locale == [],
             """
             Locale '#{locale}' is missing msgids in #{po_file}:
             #{inspect(missing_in_locale, pretty: true)}
             """

      assert extra_in_locale == [],
             """
             Locale '#{locale}' has extra msgids not in English #{po_file}:
             #{inspect(extra_in_locale, pretty: true)}
             """

      assert length(msgids) == length(reference_msgids),
             "Locale '#{locale}' has #{length(msgids)} msgids, expected #{length(reference_msgids)}"
    end
  end

  defp for_each_locale_and_file(po_files, assertion_fn) do
    supported_locales = LocaleHandler.supported_locales()

    for locale <- supported_locales, po_file <- po_files do
      assertion_fn.(locale, po_file)
    end
  end

  defp assert_no_empty_translations(locale, po_file) do
    po_path = Path.join([@gettext_path, locale, "LC_MESSAGES", po_file])
    content = File.read!(po_path)

    # Find all msgid/msgstr pairs
    pairs = extract_msgid_msgstr_pairs(content)

    empty_translations =
      pairs
      |> Enum.filter(fn {msgid, msgstr} ->
        # Skip the header entry (empty msgid)
        msgid != "" && msgstr == ""
      end)
      |> Enum.map(fn {msgid, _msgstr} -> msgid end)

    assert empty_translations == [],
           """
           Locale '#{locale}' has empty translations in #{po_file}:
           #{inspect(empty_translations, pretty: true)}
           """
  end

  defp assert_proper_headers(locale, po_file) do
    po_path = Path.join([@gettext_path, locale, "LC_MESSAGES", po_file])
    content = File.read!(po_path)

    # Check for required header fields
    assert content =~ ~r/Language: #{locale}/,
           "#{locale}/#{po_file} missing Language header"

    assert content =~ ~r/Plural-Forms:/,
           "#{locale}/#{po_file} missing Plural-Forms header"
  end

  defp get_msgids_by_locale(po_file) do
    supported_locales = LocaleHandler.supported_locales()

    for locale <- supported_locales, into: %{} do
      po_path = Path.join([@gettext_path, locale, "LC_MESSAGES", po_file])
      msgids = extract_msgids(po_path)
      {locale, msgids}
    end
  end

  defp extract_msgids(po_path) do
    po_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case String.trim(line) do
        # Skip empty msgid (header entry)
        "msgid \"\"" ->
          acc

        # Extract msgid
        <<"msgid \"", rest::binary>> ->
          msgid = String.trim_trailing(rest, "\"")
          [msgid | acc]

        _non_msgid_line ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp extract_msgid_msgstr_pairs(content) do
    lines = String.split(content, "\n")

    lines
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        trimmed = String.trim(line)

        cond do
          # Start of msgid
          String.starts_with?(trimmed, "msgid \"") ->
            msgid = extract_quoted_value(trimmed, "msgid")
            {:cont, {:msgid, msgid}}

          # msgstr or msgstr[0] (plural) following msgid
          (String.starts_with?(trimmed, "msgstr \"") ||
             String.starts_with?(trimmed, "msgstr[0] \"")) &&
              match?({:msgid, _msgid}, acc) ->
            {:msgid, msgid} = acc
            prefix = if String.starts_with?(trimmed, "msgstr["), do: "msgstr[0]", else: "msgstr"
            msgstr = extract_quoted_value(trimmed, prefix)
            {:cont, {msgid, msgstr}, nil}

          true ->
            {:cont, acc}
        end
      end,
      fn
        {:msgid, msgid} -> {:cont, {msgid, ""}, nil}
        _acc -> {:cont, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
  end

  defp extract_quoted_value(line, prefix) do
    line
    |> String.trim_leading(prefix <> " \"")
    |> String.trim_trailing("\"")
  end

  defp get_file_sizes(locale) do
    for po_file <- @translated_files, into: %{} do
      po_path = Path.join([@gettext_path, locale, "LC_MESSAGES", po_file])
      size = File.stat!(po_path).size
      {po_file, size}
    end
  end
end
