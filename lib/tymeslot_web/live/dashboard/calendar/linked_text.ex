defmodule TymeslotWeb.Dashboard.Calendar.LinkedText do
  @moduledoc """
  An event's place or notes as text in which every web address is a link,
  for the preview and the side panel of an event that cannot be edited.

  Only `http` and `https` addresses with a host become links, opened in a
  new tab with `rel="noopener noreferrer"`; everything else stays text.
  The markup is built by HEEx, so the text and the address are escaped like
  any other assign. Punctuation that ends a sentence is left out of the
  address it follows ("see https://example.com." links the address alone),
  and an address longer than 2048 bytes stays text.
  """

  use TymeslotWeb, :html

  @url ~r{https?://[^\s<>"']+}i
  @punctuation ~c".,;:!?"
  # Each closing bracket, and the closing bracket each opening one pairs with.
  @closing %{?) => ?(, ?] => ?[, ?} => ?{}
  @opening Map.new(@closing, fn {close, open} -> {open, close} end)

  # An address longer than this is left as text: no real link needs it, and
  # notes come from outside invitations and feeds.
  @max_address_bytes 2_048

  @typedoc "A run of plain text, or a web address to link."
  @type part :: {:text, String.t()} | {:link, String.t()}

  @doc "`text` split into plain runs and the web addresses in it, in order."
  @spec parts(String.t()) :: [part()]
  def parts(text) when is_binary(text) do
    @url
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.flat_map(&classify/1)
    |> merge_text()
  end

  defp classify(chunk) do
    if Regex.match?(~r{\Ahttps?://}i, chunk) do
      {address, tail} = split_trailing(chunk)

      if byte_size(address) <= @max_address_bytes and web_address?(address),
        do: [{:link, address}, {:text, tail}],
        else: [{:text, chunk}]
    else
      [{:text, chunk}]
    end
  end

  # Sentence punctuation after an address is not part of it, nor is a
  # closing bracket the address does not open itself: "(see
  # https://example.com)" ends before the bracket, while
  # "https://en.wikipedia.org/wiki/Foo_(bar)" keeps it. One pass from the
  # end, with the brackets counted once, so a long run of them costs no more
  # than its length. Every character that can trail is a single byte.
  defp split_trailing(chunk) do
    cut = trailing_start(chunk, byte_size(chunk), bracket_balance(chunk))
    {binary_part(chunk, 0, cut), binary_part(chunk, cut, byte_size(chunk) - cut)}
  end

  # How many more closing than opening brackets of each kind `chunk` holds.
  defp bracket_balance(chunk) do
    for <<byte <- chunk>>, reduce: %{} do
      balance ->
        cond do
          Map.has_key?(@closing, byte) -> Map.update(balance, byte, 1, &(&1 + 1))
          Map.has_key?(@opening, byte) -> Map.update(balance, @opening[byte], -1, &(&1 - 1))
          true -> balance
        end
    end
  end

  defp trailing_start(_chunk, 0, _balance), do: 0

  defp trailing_start(chunk, at, balance) do
    byte = :binary.at(chunk, at - 1)

    cond do
      byte in @punctuation ->
        trailing_start(chunk, at - 1, balance)

      Map.has_key?(@closing, byte) and Map.get(balance, byte, 0) > 0 ->
        trailing_start(chunk, at - 1, Map.update!(balance, byte, &(&1 - 1)))

      true ->
        at
    end
  end

  defp web_address?(address) do
    case URI.new(address) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _invalid ->
        false
    end
  end

  # Adjacent runs of text join, and empty ones go.
  defp merge_text(parts) do
    parts
    |> Enum.reject(&(&1 == {:text, ""}))
    |> Enum.chunk_while(
      nil,
      fn
        {:text, b}, {:text, a} -> {:cont, {:text, a <> b}}
        part, nil -> {:cont, part}
        part, acc -> {:cont, acc, part}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
  end

  attr :text, :string, required: true
  attr :rest, :global

  @doc "Renders `text` with its web addresses as links that open in a new tab."
  @spec linked_text(map()) :: Phoenix.LiveView.Rendered.t()
  def linked_text(assigns) do
    assigns = assign(assigns, :parts, parts(assigns.text))

    ~H"""
    <span {@rest}><.part :for={part <- @parts} part={part} /></span>
    """
  end

  defp part(%{part: {:link, url}} = assigns) do
    assigns = assign(assigns, :url, url)

    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="break-all text-turquoise-700 underline hover:text-turquoise-800"
    >{@url}</a>
    """
  end

  defp part(%{part: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :text, :string, default: nil

  @doc """
  A field of an event that cannot be edited, as text with its links: the
  label and the value, or nothing at all when the value is empty.
  """
  @spec read_only_field(map()) :: Phoenix.LiveView.Rendered.t()
  def read_only_field(assigns) do
    ~H"""
    <div :if={is_binary(@text) and String.trim(@text) != ""} id={@id}>
      <p class="mb-1 text-token-sm font-medium text-tymeslot-700">{@label}</p>
      <.linked_text
        text={@text}
        class="block whitespace-pre-line break-words text-token-sm text-tymeslot-900"
      />
    </div>
    """
  end
end
