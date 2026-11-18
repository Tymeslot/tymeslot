defmodule TymeslotWeb.Dashboard.Calendar.LinkedText do
  @moduledoc """
  An event's place or notes as text in which every web address is a link,
  for the preview and the side panel of an event that cannot be edited.

  Only `http` and `https` addresses with a host become links, opened in a
  new tab with `rel="noopener noreferrer"`; everything else stays text.
  The markup is built by HEEx, so the text and the address are escaped like
  any other assign. Punctuation that ends a sentence is left out of the
  address it follows ("see https://example.com." links the address alone).
  """

  use TymeslotWeb, :html

  @url ~r{https?://[^\s<>"']+}i
  @trailing ~r/[.,;:!?)\]}]+$/

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
      if web_address?(address), do: [{:link, address}, {:text, tail}], else: [{:text, chunk}]
    else
      [{:text, chunk}]
    end
  end

  defp split_trailing(chunk) do
    case Regex.run(@trailing, chunk, return: :index) do
      [{at, _length}] -> String.split_at(chunk, at)
      nil -> {chunk, ""}
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
