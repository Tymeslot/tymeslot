defmodule TymeslotWeb.GettextCompletenessTest do
  @moduledoc """
  Tests to ensure translation completeness across all supported languages.
  Verifies that:
  - All languages have the same msgids
  - No translations are missing
  - .po files are properly formatted
  """
  use ExUnit.Case, async: true

  alias TymeslotWeb.Themes.Shared.LocaleHandler

  @gettext_path Path.expand("../../priv/gettext", __DIR__)
  @po_files ["default.po", "errors.po"]

  describe "translation completeness" do
    test "all supported locales have translation files" do
      supported_locales = LocaleHandler.supported_locales()

      for locale <- supported_locales do
        locale_dir = Path.join([@gettext_path, locale, "LC_MESSAGES"])

        assert File.dir?(locale_dir),
               "Missing LC_MESSAGES directory for locale: #{locale}"

        for po_file <- @po_files do
          po_path = Path.join(locale_dir, po_file)

          assert File.exists?(po_path),
                 "Missing translation file: #{locale}/LC_MESSAGES/#{po_file}"
        end
      end
    end

    test "all locales have the same msgids in default.po" do
      msgids_by_locale = get_msgids_by_locale("default.po")

      # Get English as reference (should be complete)
      reference_msgids = msgids_by_locale["en"]
      assert reference_msgids != [], "English default.po has no msgids"

      # Check all other locales have the same msgids
      for {locale, msgids} <- msgids_by_locale do
        missing_in_locale = reference_msgids -- msgids
        extra_in_locale = msgids -- reference_msgids

        assert missing_in_locale == [],
               """
               Locale '#{locale}' is missing msgids in default.po:
               #{inspect(missing_in_locale, pretty: true)}
               """

        assert extra_in_locale == [],
               """
               Locale '#{locale}' has extra msgids not in English default.po:
               #{inspect(extra_in_locale, pretty: true)}
               """

        assert length(msgids) == length(reference_msgids),
               "Locale '#{locale}' has #{length(msgids)} msgids, expected #{length(reference_msgids)}"
      end
    end

    test "all locales have the same msgids in errors.po" do
      msgids_by_locale = get_msgids_by_locale("errors.po")

      reference_msgids = msgids_by_locale["en"]
      assert reference_msgids != [], "English errors.po has no msgids"

      for {locale, msgids} <- msgids_by_locale do
        missing_in_locale = reference_msgids -- msgids
        extra_in_locale = msgids -- reference_msgids

        assert missing_in_locale == [],
               """
               Locale '#{locale}' is missing msgids in errors.po:
               #{inspect(missing_in_locale, pretty: true)}
               """

        assert extra_in_locale == [],
               """
               Locale '#{locale}' has extra msgids not in English errors.po:
               #{inspect(extra_in_locale, pretty: true)}
               """

        assert length(msgids) == length(reference_msgids),
               "Locale '#{locale}' has #{length(msgids)} msgids, expected #{length(reference_msgids)}"
      end
    end

    test "no empty translations (msgstr) in any locale" do
      supported_locales = LocaleHandler.supported_locales()

      for locale <- supported_locales, po_file <- @po_files do
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
    end

    test "all .po files have proper headers" do
      supported_locales = LocaleHandler.supported_locales()

      for locale <- supported_locales, po_file <- @po_files do
        po_path = Path.join([@gettext_path, locale, "LC_MESSAGES", po_file])
        content = File.read!(po_path)

        # Check for required header fields
        assert content =~ ~r/Language: #{locale}/,
               "#{locale}/#{po_file} missing Language header"

        assert content =~ ~r/Plural-Forms:/,
               "#{locale}/#{po_file} missing Plural-Forms header"
      end
    end

    test "translation file sizes are reasonable" do
      # English is the reference - other translations shouldn't be much smaller
      # (which might indicate missing content)
      reference_sizes = get_file_sizes("en")

      supported_locales = LocaleHandler.supported_locales() -- ["en"]

      for locale <- supported_locales, po_file <- @po_files do
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

          # msgstr following msgid
          String.starts_with?(trimmed, "msgstr \"") && match?({:msgid, _msgid}, acc) ->
            {:msgid, msgid} = acc
            msgstr = extract_quoted_value(trimmed, "msgstr")
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
    for po_file <- @po_files, into: %{} do
      po_path = Path.join([@gettext_path, locale, "LC_MESSAGES", po_file])
      size = File.stat!(po_path).size
      {po_file, size}
    end
  end
end
