defmodule Tymeslot.Infrastructure.DotenvLoader do
  require Logger

  @moduledoc """
  Populates the system environment from a `.env` file as a fallback for
  shell-supplied variables.

  Shell environment variables always win — values from `.env` are only
  applied to keys that are not already set. This lets operators configure
  releases by dropping a flat `.env` at the release root while still
  allowing one-off shell overrides.

  Invoked at the top of `config/runtime.exs` so the rest of runtime
  configuration sees a populated environment via `System.get_env/1`.

  ## The grammar

  On Cloudron the same file is read twice: `start.sh`'s `load_env_file`
  applies it before the release boots, and this module applies it again
  from `config/runtime.exs` (and in every `cloudron exec` eval session).
  A value the two read differently is a value an operator cannot reason
  about, so the parser below implements exactly the grammar that shell
  reader accepts, and nothing else. `start.sh` is the specification;
  `DotenvLoaderTest` runs both over one fixture and compares.

    * A line is stripped of a trailing `\\r`, then of leading whitespace.
      Empty lines and lines starting with `#` are ignored.
    * One leading `export ` is dropped.
    * The key is everything before the first `=`, trailing whitespace
      removed, and must match `[A-Za-z_][A-Za-z0-9_]*`.
    * The value is everything after the first `=`, read in one of three
      ways depending on its first non-whitespace character:
      * `'single quoted'` is literal, character for character, up to the
        next `'`. There is no escape for a single quote.
      * `"double quoted"` runs to the first unescaped `"`, resolving
        `\\n \\r \\t \\f \\b`, `\\uXXXX`, and a backslash before any other
        character as that bare character.
      * Anything else is literal up to the first whitespace-preceded `#`,
        with leading and trailing whitespace removed. The `#` test runs
        before the leading whitespace comes off, so `KEY= # note` is empty.
    * After a closing quote only whitespace and a `#` comment may follow;
      any other text rejects the line. That is also how a quote inside a
      value shows up: `'it's'` closes early and leaves `s'` behind.
    * There is no interpolation and no command substitution: `${VAR}` and
      `$(cmd)` are ordinary text wherever they appear.
    * A value whose quote never closes (a multi-line value) is rejected
      rather than guessed at, matching the shell reader, which is
      line-oriented and cannot do otherwise.
    * A key repeated in one file takes its last value.

  The one place agreement stops is application, not parsing. A `\\uXXXX`
  escape naming a surrogate encodes to the same bytes here as in the
  shell, but those bytes are not valid UTF-8, so `apply_var/2` skips the
  key rather than let `System.put_env/2` raise during boot.
  """

  @whitespace ~c" \t\v\f\r"
  @hex ~c"0123456789abcdefABCDEF"

  # The longest suffix beginning with whitespace followed by `#`, which is what
  # `${value%%[[:space:]]#*}` removes. A `#` not preceded by whitespace is part
  # of the value.
  @comment_starts [" #", "\t#", "\v#", "\f#", "\r#"]

  @doc """
  Loads each `.env` path in order and applies any keys that are not yet
  set in the system environment.

  Missing files are silently skipped — boot must never fail because an
  optional `.env` is absent. Lines that do not parse log a warning naming
  their line numbers and are skipped individually; one bad line never
  costs the file its other values.
  """
  @spec load([Path.t()]) :: :ok
  def load(paths) when is_list(paths) do
    Enum.each(paths, &load_one/1)
  end

  defp load_one(path) do
    case File.read(path) do
      {:ok, contents} ->
        {vars, rejected} = parse(contents)
        Enum.each(vars, &apply_var(&1, path))
        warn_rejected(rejected, path)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("DotenvLoader: cannot read .env file", path: path, reason: reason)
    end
  end

  defp warn_rejected([], _path), do: :ok

  defp warn_rejected(rejected, path) do
    # The numbers, never the content: a rejected line is as likely to hold a
    # secret as any other, and this warning goes to the same log as everything
    # else. `reason` rather than a key of its own because that is the one the
    # console formatter renders in dev and test.
    lines = rejected |> Enum.reverse() |> Enum.map_join(", ", &"line #{&1}")

    Logger.warning("DotenvLoader: skipping unparsable .env lines",
      path: path,
      reason: lines
    )
  end

  # `System.put_env/2` raises on a value that is not valid UTF-8, which a file
  # saved as Latin-1 produces, or that contains a raw NUL byte (valid UTF-8,
  # but `os:putenv/2` rejects it), and a raise here would take down every boot
  # and `eval` session that reads the file. Such a value is skipped with a
  # warning naming the key instead.
  #
  # The `System.get_env/1` check comes first deliberately: a key the shell
  # already set is not ours to touch, valid or not.
  defp apply_var({key, value}, path) do
    cond do
      System.get_env(key) != nil ->
        :ok

      String.valid?(value) and not String.contains?(value, <<0>>) ->
        System.put_env(key, value)

      true ->
        Logger.warning(
          "DotenvLoader: skipping #{key} in #{path}: its value is not valid UTF-8; " <>
            "save the file as UTF-8 or set the variable in the environment instead"
        )
    end
  end

  # Returns the variables the file assigns, last value winning, and the numbers
  # of the lines that were rejected.
  @spec parse(binary()) :: {%{optional(String.t()) => String.t()}, [pos_integer()]}
  defp parse(contents) do
    contents
    |> :binary.split("\n", [:global])
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, []}, fn {line, number}, {vars, rejected} ->
      case parse_line(line) do
        {:ok, key, value} -> {Map.put(vars, key, value), rejected}
        :ignore -> {vars, rejected}
        :reject -> {vars, [number | rejected]}
      end
    end)
  end

  defp parse_line(raw) do
    line = raw |> strip_carriage_return() |> trim_leading()

    case line do
      "" -> :ignore
      "#" <> _comment -> :ignore
      "export " <> rest -> assignment(rest)
      _assignment -> assignment(line)
    end
  end

  defp assignment(line) do
    with [raw_key, raw_value] <- :binary.split(line, "="),
         key = trim_trailing(raw_key),
         true <- valid_key?(key),
         {:ok, value} <- parse_value(raw_value) do
      {:ok, key, value}
    else
      _no_assignment -> :reject
    end
  end

  defp parse_value(raw) do
    case trim_leading(raw) do
      <<?", quoted::binary>> ->
        with {:ok, value, tail} <- unescape(quoted, ""), do: closed(value, tail)

      # Literal up to the next quote. There is no escape for one, so a quote the
      # value itself holds leaves text after the close and `closed/2` rejects.
      <<?', quoted::binary>> ->
        case :binary.split(quoted, "'") do
          [value, tail] -> closed(value, tail)
          [_never_closed] -> :reject
        end

      # The comment is cut before the leading whitespace comes off, so the
      # space in `KEY= # note` still marks the `#` as a comment.
      _unquoted ->
        {:ok, raw |> cut_at_comment() |> trim_leading() |> trim_trailing()}
    end
  end

  # After a closing quote only whitespace and a comment may follow.
  defp closed(value, tail) do
    case trim_leading(tail) do
      "" -> {:ok, value}
      "#" <> _comment -> {:ok, value}
      _trailing_text -> :reject
    end
  end

  # Unescapes up to the first unescaped `"`, returning the value and whatever
  # followed the closing quote. Running out of input means the quote never
  # closed: a multi-line value, or a closing quote that was itself escaped.
  defp unescape("", _acc), do: :reject
  defp unescape(<<?", tail::binary>>, acc), do: {:ok, acc, tail}
  defp unescape(<<?\\>>, _acc), do: :reject
  defp unescape(<<?\\, ?n, rest::binary>>, acc), do: unescape(rest, acc <> "\n")
  defp unescape(<<?\\, ?r, rest::binary>>, acc), do: unescape(rest, acc <> "\r")
  defp unescape(<<?\\, ?t, rest::binary>>, acc), do: unescape(rest, acc <> "\t")
  defp unescape(<<?\\, ?f, rest::binary>>, acc), do: unescape(rest, acc <> "\f")
  defp unescape(<<?\\, ?b, rest::binary>>, acc), do: unescape(rest, acc <> "\b")

  defp unescape(<<?\\, ?u, a, b, c, d, rest::binary>>, acc)
       when a in @hex and b in @hex and c in @hex and d in @hex do
    codepoint = String.to_integer(<<a, b, c, d>>, 16)
    unescape(rest, acc <> utf8(codepoint))
  end

  defp unescape(<<?\\, ?u, _rest::binary>>, _acc), do: :reject
  defp unescape(<<?\\, char, rest::binary>>, acc), do: unescape(rest, acc <> <<char>>)
  defp unescape(<<char, rest::binary>>, acc), do: unescape(rest, acc <> <<char>>)

  # Encodes one `\uXXXX` codepoint exactly as `start.sh`'s `dotenv_utf8` does,
  # by hand rather than through `<<codepoint::utf8>>`: the two have to produce
  # the same bytes for every input, including the surrogates and the NUL that
  # `::utf8` refuses and a shell cannot hold. Four hex digits reach 0xFFFF at
  # most, so three bytes always suffice.
  defp utf8(0), do: ""
  defp utf8(codepoint) when codepoint < 0x80, do: <<codepoint>>

  defp utf8(codepoint) when codepoint < 0x800 do
    <<0xC0 + div(codepoint, 64), 0x80 + rem(codepoint, 64)>>
  end

  defp utf8(codepoint) do
    <<0xE0 + div(codepoint, 4096), 0x80 + rem(div(codepoint, 64), 64), 0x80 + rem(codepoint, 64)>>
  end

  defp cut_at_comment(value) do
    case :binary.match(value, @comment_starts) do
      {position, _length} -> binary_part(value, 0, position)
      :nomatch -> value
    end
  end

  defp valid_key?(<<char, rest::binary>>) when char in ?A..?Z or char in ?a..?z or char == ?_ do
    key_tail?(rest)
  end

  defp valid_key?(_key), do: false

  defp key_tail?(""), do: true

  defp key_tail?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_ do
    key_tail?(rest)
  end

  defp key_tail?(_rest), do: false

  defp strip_carriage_return(""), do: ""

  defp strip_carriage_return(line) do
    case :binary.last(line) do
      ?\r -> binary_part(line, 0, byte_size(line) - 1)
      _other -> line
    end
  end

  defp trim_leading(<<char, rest::binary>>) when char in @whitespace, do: trim_leading(rest)
  defp trim_leading(binary), do: binary

  defp trim_trailing(""), do: ""

  defp trim_trailing(binary) do
    if :binary.last(binary) in @whitespace do
      trim_trailing(binary_part(binary, 0, byte_size(binary) - 1))
    else
      binary
    end
  end
end
