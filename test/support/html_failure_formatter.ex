defmodule Tymeslot.Test.HtmlFailureFormatter do
  @moduledoc """
  `ExUnit.CLIFormatter` with readable `=~` failures on rendered HTML.

  View, controller and email tests check output with `assert html =~ "text"`.
  When one fails, ExUnit prints the whole left-hand side, which is the entire
  rendered document (head, scripts, inline SVG), so the useful part is buried
  under tens of kilobytes. This formatter rewrites such failures before the CLI
  formatter prints them: `left:` becomes a one-line summary and the message
  gains a short excerpt instead.

    * `assert` with plain text: the visible text of `<main>` (or `<body>`, or
      the whole fragment), plus the nearest partial match when there is one.
    * `assert` with markup (`<`, `=` or `"` in the expected value) or a regex:
      the region of raw HTML around the nearest partial match, since visible
      text would hide exactly what the assertion checks.
    * `refute`: the raw HTML around where the unwanted text was found.

  Only `=~` failures whose left side is a string longer than
  2,000 bytes are touched; everything else reaches the CLI formatter
  unchanged. Wired in through `Tymeslot.Test.SuiteConfig.formatters/0`.
  """

  use GenServer

  alias ExUnit.AssertionError
  alias ExUnit.CLIFormatter

  @min_size 2_000
  @text_limit 1_500
  @window 300
  @min_anchor 4

  @impl GenServer
  def init(opts), do: CLIFormatter.init(opts)

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, config) do
    CLIFormatter.handle_cast(
      {:test_finished, %{test | state: {:failed, shorten_all(failures)}}},
      config
    )
  end

  def handle_cast(
        {:module_finished, %ExUnit.TestModule{state: {:failed, failures}} = test_module},
        config
      ) do
    CLIFormatter.handle_cast(
      {:module_finished, %{test_module | state: {:failed, shorten_all(failures)}}},
      config
    )
  end

  def handle_cast(event, config), do: CLIFormatter.handle_cast(event, config)

  @doc """
  Rewrites an `=~` assertion error on a long string; returns any other
  error unchanged.
  """
  @spec shorten(term()) :: term()
  def shorten(
        %AssertionError{left: left, right: right, message: "Assertion with =~ failed"} = error
      )
      when is_binary(left) and byte_size(left) > @min_size and
             (is_binary(right) or is_struct(right, Regex)) do
    rewrite(error, assert_excerpt(left, right))
  end

  def shorten(%AssertionError{left: left, right: right, message: "Refute with =~ failed"} = error)
      when is_binary(left) and byte_size(left) > @min_size and
             (is_binary(right) or is_struct(right, Regex)) do
    rewrite(error, refute_excerpt(left, right))
  end

  def shorten(error), do: error

  defp shorten_all(failures) do
    for {kind, reason, stack} <- failures, do: {kind, shorten(reason), stack}
  end

  defp rewrite(%AssertionError{left: left, message: message} = error, excerpt) do
    %{
      error
      | message: message <> "\n\n" <> excerpt,
        left: "<#{byte_size(left)} bytes of rendered output, excerpt above>"
    }
  end

  defp assert_excerpt(html, expected) do
    partial = nearest_partial(html, expected)

    cond do
      markup?(expected) and partial ->
        partial_section(html, partial, expected)

      partial ->
        visible_text_section(html) <> "\n\n" <> partial_section(html, partial, expected)

      true ->
        visible_text_section(html) <> "\n\nNo partial match found."
    end
  end

  defp refute_excerpt(html, unwanted) do
    {start, length} =
      case unwanted do
        %Regex{} -> unwanted |> Regex.run(html, return: :index) |> hd()
        text -> :binary.match(html, text)
      end

    "Unwanted match at byte #{start}:\n" <> raw_window(html, start, length)
  end

  defp partial_section(html, {anchor, start}, expected) do
    "Nearest partial match (#{inspect(anchor)} of #{inspect(expected)}) at byte #{start}:\n" <>
      raw_window(html, start, byte_size(anchor))
  end

  defp visible_text_section(html) do
    {label, text} = visible_text(html)
    "Visible text of #{label}:\n" <> truncate(text, @text_limit)
  end

  # The longest literal prefix of the expected value that does occur, so a
  # reader sees where the page diverged from what the test expected.
  defp nearest_partial(html, expected) do
    prefix = literal_prefix(expected)

    Enum.find_value(byte_size(prefix)..@min_anchor//-1, fn size ->
      anchor = binary_part(prefix, 0, size)

      if String.valid?(anchor) do
        case :binary.match(html, anchor) do
          {start, _length} -> {anchor, start}
          :nomatch -> nil
        end
      end
    end)
  end

  defp literal_prefix(%Regex{source: source}) do
    source
    |> String.split(~r/[\\.^$|?*+()\[\]{}]/, parts: 2)
    |> hd()
  end

  defp literal_prefix(text), do: text

  defp markup?(%Regex{}), do: true
  defp markup?(text), do: String.contains?(text, ["<", "=", "\""])

  defp visible_text(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        Enum.find_value(["main", "body"], {"the output", text_of(document)}, fn selector ->
          case Floki.find(document, selector) do
            [] -> nil
            nodes -> {"<#{selector}>", text_of(nodes)}
          end
        end)

      {:error, _reason} ->
        {"the output", html}
    end
  end

  defp text_of(nodes) do
    nodes
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp raw_window(html, start, length) do
    from = max(start - @window, 0)
    to = min(start + length + @window, byte_size(html))

    prefix = if from > 0, do: "…", else: ""
    suffix = if to < byte_size(html), do: "…", else: ""

    prefix <> valid_slice(html, from, to - from) <> suffix
  end

  # A byte window can cut a multi-byte character in half at either end.
  defp valid_slice(binary, from, length) do
    binary
    |> binary_part(from, length)
    |> String.replace_invalid("")
  end

  defp truncate(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end
end
