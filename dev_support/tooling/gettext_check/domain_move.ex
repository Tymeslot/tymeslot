defmodule Tymeslot.GettextCheck.DomainMove do
  @moduledoc """
  The pure steps behind `mix gettext.move_domain`: pointing the gettext calls
  in a set of source files at another domain, and carrying every locale's
  existing translations into that domain once extraction has rebuilt the
  catalogues.

  Extraction creates a new domain's `.po` files with empty msgstrs, and when
  the target domain already exists, `--merge` may fuzzy-match a moved entry
  against an unrelated obsolete one and copy the wrong translation. Both are
  repaired from a snapshot of the catalogues taken before the move, keyed by
  `{msgctxt, msgid}`, so nothing translated before the move ships empty or
  wrong after it.
  """

  alias Expo.Message
  alias Expo.Messages
  alias Expo.PO

  @type snapshot :: %{String.t() => %{term() => Message.t()}}

  @doc """
  Rewrites the domain argument of every gettext call in `source` naming
  `from`, returning the new source and the number of calls rewritten.

  Covers the `d*gettext` macros and their `_noop` forms, and runtime
  `Gettext.d*gettext(Backend, "domain", ...)` lookups. A domain held in a
  variable or attribute is not a literal call argument and is left alone;
  `runtime_references/2` finds those.
  """
  @spec rewrite_source(String.t(), String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def rewrite_source(source, from, to) do
    Enum.reduce(call_patterns(from), {source, 0}, fn pattern, {acc, count} ->
      hits = length(Regex.scan(pattern, acc))
      {Regex.replace(pattern, acc, "\\1\"#{to}\""), count + hits}
    end)
  end

  @doc """
  Lines of `source` that still spell `"from"` as a string literal outside a
  gettext call: a domain stored in a map or attribute and looked up later,
  which a move must update by hand or the moved strings fall back to English.
  """
  @spec runtime_references(String.t(), String.t()) :: [{pos_integer(), String.t()}]
  def runtime_references(source, from) do
    literal = ~s("#{from}")

    # Calls are masked over the whole source, not per line, since the formatter
    # often puts the domain on the line after `dgettext(`. The captured prefix
    # keeps its newlines, so line numbers survive the masking.
    masked = Enum.reduce(call_patterns(from), source, &Regex.replace(&1, &2, "\\1_"))

    masked
    |> String.split("\n")
    |> Enum.zip(String.split(source, "\n"))
    |> Enum.with_index(1)
    |> Enum.filter(fn {{masked_line, _line}, _number} ->
      String.contains?(masked_line, literal)
    end)
    |> Enum.map(fn {{_masked, line}, number} -> {number, String.trim(line)} end)
  end

  @doc """
  Every locale's messages for `domains`, keyed by locale and then by
  `Expo.Message.key/1`. Only translated messages are kept.
  """
  @spec snapshot(Path.t(), [String.t()]) :: snapshot()
  def snapshot(priv, domains) do
    Map.new(locales(priv), fn locale ->
      messages =
        for domain <- domains,
            path = po_path(priv, locale, domain),
            File.exists?(path),
            message <- PO.parse_file!(path).messages,
            translated?(message) and not fuzzy?(message),
            into: %{},
            do: {Message.key(message), message}

      {locale, messages}
    end)
  end

  @doc """
  Fills `domain`'s `.po` in every non-English locale from `snapshot`: each
  empty or fuzzy entry whose key the snapshot holds takes the snapshot's
  msgstr, and loses its fuzzy flag. In English, where every msgstr stays
  empty, a fuzzy match is simply unflagged and blanked. Returns the keys
  still untranslated, per non-English locale, after the fill.
  """
  @spec carry(Path.t(), String.t(), snapshot()) :: %{String.t() => [term()]}
  def carry(priv, domain, snapshot) do
    results =
      for locale <- locales(priv), into: %{} do
        path = po_path(priv, locale, domain)
        %Messages{} = po = PO.parse_file!(path)

        messages =
          if locale == "en",
            do: Enum.map(po.messages, &unfuzz_english/1),
            else: Enum.map(po.messages, &fill(&1, Map.get(snapshot, locale, %{})))

        File.write!(path, PO.compose(%{po | messages: messages}))

        {locale, for(m <- messages, not translated?(m) or fuzzy?(m), do: Message.key(m))}
      end

    Map.delete(results, "en")
  end

  @doc "The locale directories under `priv`."
  @spec locales(Path.t()) :: [String.t()]
  def locales(priv) do
    priv
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join([priv, &1, "LC_MESSAGES"])))
    |> Enum.sort()
  end

  defp fill(message, known) do
    with true <- not translated?(message) or fuzzy?(message),
         {:ok, source} <- Map.fetch(known, Message.key(message)) do
      %{message | msgstr: source.msgstr, flags: drop_fuzzy(message.flags)}
    else
      _untranslatable -> message
    end
  end

  defp unfuzz_english(%Message.Singular{} = message) do
    if fuzzy?(message),
      do: %{message | msgstr: [""], flags: drop_fuzzy(message.flags)},
      else: message
  end

  defp unfuzz_english(%Message.Plural{} = message) do
    if fuzzy?(message),
      do: %{
        message
        | msgstr: Map.new(message.msgstr, fn {n, _msgstr} -> {n, [""]} end),
          flags: drop_fuzzy(message.flags)
      },
      else: message
  end

  defp call_patterns(from) do
    domain = Regex.escape(~s("#{from}"))

    [
      ~r/(\bd(?:n|p|pn)?gettext(?:_noop)?\(\s*)#{domain}/,
      ~r/(\bGettext\.d(?:n|p|pn)?gettext\(\s*[A-Za-z0-9_.]+,\s*)#{domain}/
    ]
  end

  defp translated?(%Message.Singular{msgstr: msgstr}), do: IO.iodata_to_binary(msgstr) != ""

  defp translated?(%Message.Plural{msgstr: msgstr}),
    do: msgstr != %{} and Enum.all?(msgstr, fn {_n, s} -> IO.iodata_to_binary(s) != "" end)

  defp fuzzy?(message), do: Message.has_flag?(message, "fuzzy")

  defp drop_fuzzy(flags) do
    flags
    |> Enum.map(&List.delete(&1, "fuzzy"))
    |> Enum.reject(&(&1 == []))
  end

  defp po_path(priv, locale, domain),
    do: Path.join([priv, locale, "LC_MESSAGES", domain <> ".po"])
end
