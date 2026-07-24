defmodule Mix.Tasks.Tymeslot.I18nCsv do
  @moduledoc """
  Exports all Core gettext strings to a CSV for translation review.

  Each row pairs an English source string (from the `.pot` templates) with its
  translation in every locale. Plural strings emit two rows — one for the
  singular form, one for the plural. The final `references` column lists the
  source `file:line` locations extracted from the `.pot`.

  ## Usage

      mix tymeslot.i18n_csv                 # writes /tmp/tymeslot-i18n.csv
      mix tymeslot.i18n_csv --output path/to/file.csv
  """

  use Mix.Task

  alias Expo.Message.Plural
  alias Expo.Message.Singular
  alias Expo.PO

  @shortdoc "Export gettext strings to a CSV for review"
  @default_output "/tmp/tymeslot-i18n.csv"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [output: :string])
    if invalid != [], do: Mix.raise("Unknown options: #{inspect(invalid)}")
    output = Keyword.get(opts, :output, @default_output)
    gettext_dir = resolve_gettext_dir()

    domains = list_domains(gettext_dir)
    other_locales = gettext_dir |> list_locales() |> List.delete("en")

    rows =
      Enum.flat_map(domains, fn domain ->
        template = PO.parse_file!(Path.join(gettext_dir, "#{domain}.pot"))
        english = load_locale(gettext_dir, "en", domain)
        translations = load_translations(gettext_dir, other_locales, domain)

        Enum.flat_map(
          template.messages,
          &build_rows(&1, domain, english, other_locales, translations)
        )
      end)

    header = ["domain", "plural_form", "en" | other_locales] ++ ["references"]
    File.write!(output, encode_csv([header | rows]))

    Mix.shell().info(
      "Wrote #{length(rows)} strings across #{length(domains)} domain(s) and " <>
        "#{length(other_locales) + 1} locale(s) to #{output}"
    )
  end

  defp resolve_gettext_dir do
    dir = "priv/gettext"

    if File.dir?(dir) do
      dir
    else
      Mix.raise("Could not locate Tymeslot gettext directory")
    end
  end

  defp list_domains(gettext_dir) do
    gettext_dir
    |> Path.join("*.pot")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> Path.rootname(".pot")))
    |> Enum.sort()
  end

  defp list_locales(gettext_dir) do
    gettext_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(gettext_dir, &1)))
    |> Enum.sort()
  end

  defp load_translations(gettext_dir, locales, domain) do
    Map.new(locales, &{&1, load_locale(gettext_dir, &1, domain)})
  end

  defp load_locale(gettext_dir, locale, domain) do
    path = Path.join([gettext_dir, locale, "LC_MESSAGES", "#{domain}.po"])
    if File.exists?(path), do: index_messages(PO.parse_file!(path)), else: %{}
  end

  defp index_messages(%{messages: messages}) do
    Map.new(messages, &{message_key(&1), &1})
  end

  defp message_key(%Singular{msgid: msgid}),
    do: {:singular, iodata_to_string(msgid)}

  defp message_key(%Plural{msgid: msgid, msgid_plural: msgid_plural}),
    do: {:plural, iodata_to_string(msgid), iodata_to_string(msgid_plural)}

  defp build_rows(%Singular{} = msg, domain, english, locales, translations) do
    msgid = iodata_to_string(msg.msgid)
    key = message_key(msg)
    refs = format_refs(msg.references)

    en =
      case Map.get(english, key) do
        %Singular{msgstr: msgstr} ->
          msgstr |> iodata_to_string() |> fallback(msgid)

        _other ->
          msgid
      end

    translations_row =
      Enum.map(locales, fn locale ->
        case get_in(translations, [locale, key]) do
          %Singular{msgstr: msgstr} -> iodata_to_string(msgstr)
          _other -> ""
        end
      end)

    [[domain, "", en | translations_row] ++ [refs]]
  end

  defp build_rows(%Plural{} = msg, domain, english, locales, translations) do
    ctx = %{
      domain: domain,
      key: message_key(msg),
      refs: format_refs(msg.references),
      english: english,
      locales: locales,
      translations: translations
    }

    [
      plural_row(ctx, "singular", msg.msgid, 0),
      plural_row(ctx, "plural", msg.msgid_plural, 1)
    ]
  end

  defp plural_row(ctx, form, msgid_iodata, index) do
    msgid = iodata_to_string(msgid_iodata)

    en =
      case Map.get(ctx.english, ctx.key) do
        %Plural{msgstr: msgstr} ->
          msgstr |> Map.get(index, []) |> iodata_to_string() |> fallback(msgid)

        _other ->
          msgid
      end

    translations_row =
      Enum.map(ctx.locales, fn locale ->
        case get_in(ctx.translations, [locale, ctx.key]) do
          %Plural{msgstr: msgstr} -> msgstr |> Map.get(index, []) |> iodata_to_string()
          _other -> ""
        end
      end)

    [ctx.domain, form, en | translations_row] ++ [ctx.refs]
  end

  defp fallback("", default), do: default
  defp fallback(value, _default), do: value

  defp iodata_to_string(nil), do: ""
  defp iodata_to_string(iodata), do: IO.iodata_to_binary(iodata)

  defp format_refs(nil), do: ""
  defp format_refs([]), do: ""

  defp format_refs(refs) do
    refs
    |> List.flatten()
    |> Enum.map_join(" ", fn
      {file, line} -> "#{file}:#{line}"
      file when is_binary(file) -> file
    end)
  end

  defp encode_csv(rows) do
    rows |> Enum.map_join("\r\n", &encode_row/1) |> Kernel.<>("\r\n")
  end

  defp encode_row(fields), do: Enum.map_join(fields, ",", &encode_field/1)

  defp encode_field(value) do
    string = to_string(value)

    if String.contains?(string, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(string, "\"", "\"\"")}")
    else
      string
    end
  end
end
