defmodule Tymeslot.GettextCompletenessCase.Catalogue do
  @moduledoc """
  Reads a `priv/gettext` directory for `Tymeslot.GettextCompletenessCase`.

  Each check returns a list of readable findings, empty when the catalogues are
  sound, so the test that calls it only has to assert on emptiness and explain
  what a finding means.
  """

  alias Expo.Message
  alias Expo.Messages
  alias Expo.PluralForms
  alias Expo.PO
  alias ExUnit.Assertions
  alias Tymeslot.Locales

  @placeholder ~r/%\{(\w+)\}/
  @key_style ~r/\A[a-z][a-z0-9]*(_[a-z0-9]+)+\z/

  @doc "Locales that must carry a translation for every message."
  @spec translated_locales() :: [String.t()]
  def translated_locales, do: Locales.supported_codes() -- [Locales.default_locale()]

  @doc "Every `{msgctxt, msgid}` in a domain's `.pot` template, sorted."
  @spec template_keys(Path.t(), String.t()) :: [{String.t(), String.t()}]
  def template_keys(gettext_path, domain), do: gettext_path |> pot_path(domain) |> keys()

  @doc """
  How a locale's catalogue differs from its template: `{missing, extra}`, each a
  list of formatted message keys.
  """
  @spec template_drift(Path.t(), String.t(), String.t()) :: {[String.t()], [String.t()]}
  def template_drift(gettext_path, locale, domain) do
    template = template_keys(gettext_path, domain)
    actual = gettext_path |> po_path(locale, domain) |> keys()

    {format_keys(template -- actual), format_keys(actual -- template)}
  end

  @spec missing_catalogues(Path.t(), [String.t()]) :: [String.t()]
  def missing_catalogues(gettext_path, domains) do
    for locale <- Locales.supported_codes(),
        domain <- domains,
        not File.exists?(po_path(gettext_path, locale, domain)),
        do: "#{locale}/#{domain}.po"
  end

  @spec header_problems(Path.t(), [String.t()]) :: [String.t()]
  def header_problems(gettext_path, domains) do
    for locale <- Locales.supported_codes(),
        domain <- domains,
        headers = gettext_path |> po_path(locale, domain) |> parse!() |> Map.fetch!(:headers),
        headers = Enum.join(headers),
        header <- ["Language: #{locale}", "Plural-Forms:"],
        not String.contains?(headers, header),
        do: "#{locale}/#{domain}.po is missing its `#{header}` header"
  end

  @spec oversized(Path.t(), [String.t()], pos_integer()) :: [String.t()]
  def oversized(gettext_path, domains, max_msgids) do
    for domain <- domains,
        count = length(template_keys(gettext_path, domain)),
        count > max_msgids,
        do: "#{domain}: #{count} messages"
  end

  @spec filled_source_msgstrs(Path.t(), [String.t()]) :: [String.t()]
  def filled_source_msgstrs(gettext_path, domains) do
    for domain <- domains,
        message <- messages(gettext_path, Locales.default_locale(), domain),
        not untranslated?(message),
        do: "#{domain}: #{msgid(message)}"
  end

  @spec key_style_msgids(Path.t(), [String.t()]) :: [String.t()]
  def key_style_msgids(gettext_path, domains) do
    for domain <- domains,
        {_msgctxt, msgid} <- template_keys(gettext_path, domain),
        msgid =~ @key_style,
        do: "#{domain}: #{msgid}"
  end

  @spec untranslated(Path.t(), [String.t()]) :: [String.t()]
  def untranslated(gettext_path, domains) do
    for locale <- translated_locales(),
        domain <- domains,
        message <- messages(gettext_path, locale, domain),
        untranslated?(message),
        do: "#{locale}/#{domain}: #{msgid(message)}"
  end

  @spec fuzzy(Path.t(), [String.t()]) :: [String.t()]
  def fuzzy(gettext_path, domains) do
    for locale <- Locales.supported_codes(),
        domain <- domains,
        message <- messages(gettext_path, locale, domain),
        "fuzzy" in List.flatten(message.flags),
        do: "#{locale}/#{domain}: #{msgid(message)}"
  end

  @spec placeholder_mismatches(Path.t(), [String.t()]) :: [String.t()]
  def placeholder_mismatches(gettext_path, domains) do
    for locale <- translated_locales(),
        domain <- domains,
        message <- messages(gettext_path, locale, domain),
        {unknown, dropped} = placeholder_mismatch(message),
        unknown != [] or dropped != [],
        do:
          "#{locale}/#{domain}: #{msgid(message)} " <>
            "(unknown: #{inspect(unknown)}, dropped: #{inspect(dropped)})"
  end

  @spec plural_count_mismatches(Path.t(), [String.t()]) :: [String.t()]
  def plural_count_mismatches(gettext_path, domains) do
    for locale <- Locales.supported_codes(),
        domain <- domains,
        catalogue = gettext_path |> po_path(locale, domain) |> parse!(),
        nplurals = nplurals(catalogue),
        %Message.Plural{msgstr: msgstr} = message <- catalogue.messages,
        map_size(msgstr) != nplurals,
        do: "#{locale}/#{domain}: #{msgid(message)} has #{map_size(msgstr)}, expected #{nplurals}"
  end

  @spec format_list([String.t()]) :: String.t()
  def format_list(items) do
    items
    |> Enum.sort()
    |> Enum.map_join("\n", &"      - #{inspect(String.slice(&1, 0, 90))}")
  end

  defp po_path(gettext_path, locale, domain),
    do: Path.join([gettext_path, locale, "LC_MESSAGES", "#{domain}.po"])

  defp pot_path(gettext_path, domain), do: Path.join(gettext_path, "#{domain}.pot")

  defp parse!(path) do
    PO.parse_file!(path)
  rescue
    error in PO.SyntaxError ->
      Assertions.flunk("#{path} is not a valid .po file: #{Exception.message(error)}")
  end

  defp messages(gettext_path, locale, domain),
    do: gettext_path |> po_path(locale, domain) |> messages()

  defp messages(path) do
    path
    |> parse!()
    |> Map.fetch!(:messages)
    |> Enum.reject(&(&1.obsolete or msgid(&1) == ""))
  end

  # A message is identified by its context as well as its msgid: the same msgid
  # under two contexts is two messages.
  defp keys(path) do
    path |> messages() |> Enum.map(&{text(&1.msgctxt), msgid(&1)}) |> Enum.sort()
  end

  defp format_keys(keys) do
    Enum.map(keys, fn
      {"", msgid} -> msgid
      {msgctxt, msgid} -> "[#{msgctxt}] #{msgid}"
    end)
  end

  defp msgid(message), do: text(message.msgid)

  defp untranslated?(%Message.Singular{msgstr: msgstr}), do: text(msgstr) == ""

  defp untranslated?(%Message.Plural{msgstr: msgstr}),
    do: Enum.any?(msgstr, fn {_index, str} -> text(str) == "" end)

  # Returns `{unknown, dropped}`. A plural form legitimately omits placeholders
  # (a singular often spells out the count), so only unknown ones count there.
  defp placeholder_mismatch(%Message.Singular{msgid: msgid, msgstr: msgstr}) do
    {placeholders(msgstr) -- placeholders(msgid), placeholders(msgid) -- placeholders(msgstr)}
  end

  defp placeholder_mismatch(%Message.Plural{} = message) do
    allowed = ["count" | placeholders(message.msgid) ++ placeholders(message.msgid_plural)]

    unknown =
      message.msgstr
      |> Map.values()
      |> Enum.flat_map(&placeholders/1)
      |> Enum.uniq()
      |> Kernel.--(allowed)

    {unknown, []}
  end

  defp placeholders(iodata) do
    @placeholder
    |> Regex.scan(text(iodata), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp nplurals(%Messages{} = catalogue) do
    {:ok, %PluralForms{nplurals: nplurals}} =
      catalogue |> Messages.get_header("Plural-Forms") |> Enum.join() |> PluralForms.parse()

    nplurals
  end

  defp text(nil), do: ""
  defp text(iodata), do: IO.iodata_to_binary(iodata)
end
