defmodule Tymeslot.GettextCompletenessCase.Catalogue do
  @moduledoc """
  Reads a `priv/gettext` directory for `Tymeslot.GettextCompletenessCase`.

  Each check returns a list of readable findings, empty when the catalogues are
  sound, so the test that calls it only has to assert on emptiness and explain
  what a finding means.

  Every file is parsed once, by `load/2`, and the checks read the result. Each
  check covers every locale and domain, so parsing inside each one meant reading
  the whole directory once per check; under a busy full suite that is what pushed
  a single check past ExUnit's 60-second test timeout.

  The parsed files live in `:persistent_term`, not in the struct: a `setup_all`
  context is copied into every test process, and tens of megabytes copied into
  each of some sixty tests costs more than the parsing it saves. A persistent term
  is read in place.
  """

  alias Expo.Message
  alias Expo.Messages
  alias Expo.PluralForms
  alias Expo.PO
  alias ExUnit.Assertions
  alias Tymeslot.Locales

  @placeholder ~r/%\{(\w+)\}/
  @key_style ~r/\A[a-z][a-z0-9]*(_[a-z0-9]+)+\z/

  @enforce_keys [:gettext_path, :domains]
  defstruct @enforce_keys

  @type t :: %__MODULE__{gettext_path: Path.t(), domains: [String.t()]}

  @doc """
  Parses every template and every supported locale's catalogue for `domains`,
  in parallel. A file that fails to parse is kept as its error, so the check that
  reads it fails with the reason rather than the whole module failing to set up.
  """
  @spec load(Path.t(), [String.t()]) :: t()
  def load(gettext_path, domains) do
    pots = Enum.map(domains, &pot_path(gettext_path, &1))

    pos =
      for locale <- Locales.supported_codes(),
          domain <- domains,
          do: po_path(gettext_path, locale, domain)

    files =
      (pots ++ Enum.filter(pos, &File.exists?/1))
      |> Task.async_stream(&{&1, parse(&1)}, ordered: false, timeout: :infinity)
      |> Map.new(fn {:ok, parsed} -> parsed end)

    :persistent_term.put({__MODULE__, gettext_path}, files)
    %__MODULE__{gettext_path: gettext_path, domains: domains}
  end

  @doc "Locales that must carry a translation for every message."
  @spec translated_locales() :: [String.t()]
  def translated_locales, do: Locales.supported_codes() -- [Locales.default_locale()]

  @doc "Every `{msgctxt, msgid}` in a domain's `.pot` template, sorted."
  @spec template_keys(t(), String.t()) :: [{String.t(), String.t()}]
  def template_keys(catalogues, domain),
    do: keys(catalogues, pot_path(catalogues.gettext_path, domain))

  @doc """
  How a locale's catalogue differs from its template: `{missing, extra}`, each a
  list of formatted message keys.
  """
  @spec template_drift(t(), String.t(), String.t()) :: {[String.t()], [String.t()]}
  def template_drift(catalogues, locale, domain) do
    template = template_keys(catalogues, domain)
    actual = keys(catalogues, po_path(catalogues.gettext_path, locale, domain))

    {format_keys(template -- actual), format_keys(actual -- template)}
  end

  @spec missing_catalogues(t()) :: [String.t()]
  def missing_catalogues(catalogues) do
    for locale <- Locales.supported_codes(),
        domain <- catalogues.domains,
        not Map.has_key?(files(catalogues), po_path(catalogues.gettext_path, locale, domain)),
        do: "#{locale}/#{domain}.po"
  end

  @spec header_problems(t()) :: [String.t()]
  def header_problems(catalogues) do
    for locale <- Locales.supported_codes(),
        domain <- catalogues.domains,
        headers = catalogues |> catalogue(locale, domain) |> Map.fetch!(:headers),
        headers = Enum.join(headers),
        header <- ["Language: #{locale}", "Plural-Forms:"],
        not String.contains?(headers, header),
        do: "#{locale}/#{domain}.po is missing its `#{header}` header"
  end

  @spec oversized(t(), pos_integer()) :: [String.t()]
  def oversized(catalogues, max_msgids) do
    for domain <- catalogues.domains,
        count = length(template_keys(catalogues, domain)),
        count > max_msgids,
        do: "#{domain}: #{count} messages"
  end

  @spec filled_source_msgstrs(t()) :: [String.t()]
  def filled_source_msgstrs(catalogues) do
    for domain <- catalogues.domains,
        message <- messages(catalogues, Locales.default_locale(), domain),
        not untranslated?(message),
        do: "#{domain}: #{msgid(message)}"
  end

  @spec key_style_msgids(t()) :: [String.t()]
  def key_style_msgids(catalogues) do
    for domain <- catalogues.domains,
        {_msgctxt, msgid} <- template_keys(catalogues, domain),
        msgid =~ @key_style,
        do: "#{domain}: #{msgid}"
  end

  @spec untranslated(t()) :: [String.t()]
  def untranslated(catalogues) do
    for locale <- translated_locales(),
        domain <- catalogues.domains,
        message <- messages(catalogues, locale, domain),
        untranslated?(message),
        do: "#{locale}/#{domain}: #{msgid(message)}"
  end

  @spec fuzzy(t()) :: [String.t()]
  def fuzzy(catalogues) do
    for locale <- Locales.supported_codes(),
        domain <- catalogues.domains,
        message <- messages(catalogues, locale, domain),
        "fuzzy" in List.flatten(message.flags),
        do: "#{locale}/#{domain}: #{msgid(message)}"
  end

  @spec placeholder_mismatches(t()) :: [String.t()]
  def placeholder_mismatches(catalogues) do
    for locale <- translated_locales(),
        domain <- catalogues.domains,
        message <- messages(catalogues, locale, domain),
        {unknown, dropped} = placeholder_mismatch(message),
        unknown != [] or dropped != [],
        do:
          "#{locale}/#{domain}: #{msgid(message)} " <>
            "(unknown: #{inspect(unknown)}, dropped: #{inspect(dropped)})"
  end

  @spec plural_count_mismatches(t()) :: [String.t()]
  def plural_count_mismatches(catalogues) do
    for locale <- Locales.supported_codes(),
        domain <- catalogues.domains,
        catalogue = catalogue(catalogues, locale, domain),
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

  defp parse(path) do
    case PO.parse_file(path) do
      {:ok, messages} ->
        {:ok, messages}

      {:error, reason} when is_atom(reason) ->
        {:error, reason |> :file.format_error() |> to_string()}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp files(catalogues), do: :persistent_term.get({__MODULE__, catalogues.gettext_path})

  defp parsed!(catalogues, path) do
    case Map.fetch(files(catalogues), path) do
      {:ok, {:ok, messages}} -> messages
      {:ok, {:error, reason}} -> Assertions.flunk("#{path} is not a valid .po file: #{reason}")
      :error -> Assertions.flunk("#{path} does not exist")
    end
  end

  defp catalogue(catalogues, locale, domain),
    do: parsed!(catalogues, po_path(catalogues.gettext_path, locale, domain))

  defp messages(catalogues, locale, domain),
    do: messages(catalogues, po_path(catalogues.gettext_path, locale, domain))

  defp messages(catalogues, path) do
    catalogues
    |> parsed!(path)
    |> Map.fetch!(:messages)
    |> Enum.reject(&(&1.obsolete or msgid(&1) == ""))
  end

  # A message is identified by its context as well as its msgid: the same msgid
  # under two contexts is two messages.
  defp keys(catalogues, path) do
    catalogues |> messages(path) |> Enum.map(&{text(&1.msgctxt), msgid(&1)}) |> Enum.sort()
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
    {expected, actual} = {placeholders(msgid), placeholders(msgstr)}
    {actual -- expected, expected -- actual}
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

  # This runs over every message in every locale, so skip the regex for the
  # majority of strings that hold no placeholder at all.
  defp placeholders(iodata) do
    string = text(iodata)

    if String.contains?(string, "%{") do
      @placeholder
      |> Regex.scan(string, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
    else
      []
    end
  end

  defp nplurals(%Messages{} = catalogue) do
    {:ok, %PluralForms{nplurals: nplurals}} =
      catalogue |> Messages.get_header("Plural-Forms") |> Enum.join() |> PluralForms.parse()

    nplurals
  end

  defp text(nil), do: ""
  defp text(iodata), do: IO.iodata_to_binary(iodata)
end
