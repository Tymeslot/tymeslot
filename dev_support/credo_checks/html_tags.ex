defmodule CredoChecks.HtmlTags do
  @moduledoc """
  Reads HTML tags out of a source file whole, however the formatter has
  wrapped them, for the checks that look at template markup.

  HEEx lives in the AST as strings, so markup checks read the source text.
  Reading it line by line misses every tag whose attributes the formatter has
  moved onto the following lines: the opening line holds only `<select`, and
  the attribute a check cares about sits further down. This module finds each
  opening tag in the whole source and returns it up to its closing `>`, so a
  check matches against the complete tag.

  A tag is read up to the first `>` that sits outside a quoted attribute value
  and outside a `{...}` expression, so `phx-value-n={@n > 1}` does not end it
  early. A tag on a line that is an Elixir comment, inside a HEEx comment
  (`<%!-- ... --%>`), or inside a `@moduledoc`, `@doc` or `@typedoc` heredoc is
  skipped: prose that mentions `<select>` is not a use of one.

  Each tag also carries the HEEx comment (`<%!-- ... --%>`) that directly
  precedes it, with only whitespace between, as `:comment`, or `nil`. Credo's
  own `# credo:disable-for-next-line` is an Elixir comment, which cannot sit
  inside a `~H` template, so a check that wants a per-tag exemption reads it
  from there.
  """

  alias Credo.SourceFile

  @type tag :: %{
          name: String.t(),
          line_no: pos_integer(),
          text: String.t(),
          comment: String.t() | nil
        }

  @doc """
  Returns every opening tag whose name matches `name_pattern` (a regex
  source fragment, such as `"input|select"`), in source order.

  The name must be followed by whitespace, `/` or `>`, so `<inputs` and
  `<.input` are not matches for `"input"`. Matching ignores case.
  """
  @spec tags(SourceFile.t(), String.t()) :: [tag()]
  def tags(%SourceFile{} = source_file, name_pattern) do
    source = SourceFile.source(source_file)
    regex = Regex.compile!("<(#{name_pattern})(?=[\\s/>])", "i")
    skipped_spans = heex_comment_spans(source) ++ doc_heredoc_spans(source)

    regex
    |> Regex.scan(source, return: :index)
    |> Enum.reject(fn [{start, _len} | _] ->
      comment_line?(source, start) or in_span?(skipped_spans, start)
    end)
    |> Enum.map(fn [{start, _len}, {name_start, name_len}] ->
      %{
        name: binary_part(source, name_start, name_len),
        line_no: line_no(source, start),
        text: read_tag(source, start),
        comment: preceding_comment(source, start)
      }
    end)
  end

  defp line_no(source, offset) do
    source
    |> binary_part(0, offset)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  # The `{start, length}` of every HEEx comment in the source, in order.
  defp heex_comment_spans(source) do
    ~r/<%!--.*?--%>/s
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [span] -> span end)
  end

  # The `{start, length}` of every documentation heredoc in the source.
  defp doc_heredoc_spans(source) do
    ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[Ss])?""".*?"""/s
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [span] -> span end)
  end

  defp in_span?(spans, offset),
    do: Enum.any?(spans, fn {start, len} -> offset > start and offset < start + len end)

  defp comment_line?(source, offset) do
    before = binary_part(source, 0, offset)

    line_start =
      case :binary.matches(before, "\n") do
        [] -> 0
        matches -> matches |> List.last() |> then(fn {pos, 1} -> pos + 1 end)
      end

    source
    |> binary_part(line_start, offset - line_start)
    |> String.trim_leading()
    |> String.starts_with?("#")
  end

  defp preceding_comment(source, offset) do
    before = source |> binary_part(0, offset) |> String.trim_trailing()

    with true <- String.ends_with?(before, "--%>"),
         [_ | _] = opens <- :binary.matches(before, "<%!--") do
      {open, open_len} = List.last(opens)
      body_start = open + open_len

      before
      |> binary_part(body_start, byte_size(before) - body_start - byte_size("--%>"))
      |> String.trim()
    else
      _no_comment -> nil
    end
  end

  defp read_tag(source, start) do
    rest = binary_part(source, start, byte_size(source) - start)
    length = tag_length(rest, 0, 0, nil)
    binary_part(rest, 0, length)
  end

  # Walks the tag byte by byte, tracking the `{...}` depth and the quote
  # currently open (if any), and stops after the `>` that closes the tag. An
  # unterminated tag runs to the end of the source.
  defp tag_length(<<>>, consumed, _depth, _quote), do: consumed

  defp tag_length(<<"\\", _escaped, rest::binary>>, consumed, depth, quote)
       when quote != nil,
       do: tag_length(rest, consumed + 2, depth, quote)

  defp tag_length(<<char, rest::binary>>, consumed, depth, char),
    do: tag_length(rest, consumed + 1, depth, nil)

  defp tag_length(<<_char, rest::binary>>, consumed, depth, quote) when quote != nil,
    do: tag_length(rest, consumed + 1, depth, quote)

  defp tag_length(<<char, rest::binary>>, consumed, depth, nil) when char in [?", ?'],
    do: tag_length(rest, consumed + 1, depth, char)

  defp tag_length(<<"{", rest::binary>>, consumed, depth, nil),
    do: tag_length(rest, consumed + 1, depth + 1, nil)

  defp tag_length(<<"}", rest::binary>>, consumed, depth, nil),
    do: tag_length(rest, consumed + 1, max(depth - 1, 0), nil)

  defp tag_length(<<">", _rest::binary>>, consumed, 0, nil), do: consumed + 1

  defp tag_length(<<_char, rest::binary>>, consumed, depth, nil),
    do: tag_length(rest, consumed + 1, depth, nil)
end
