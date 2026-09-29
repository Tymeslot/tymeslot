defmodule Tymeslot.Test.OutlookGraphStubs do
  @moduledoc """
  Microsoft Graph's answers to an Outlook read as they depend on the
  request, for tests that stub the HTTP client: so that a stub answers what
  Graph would for the query and headers the client actually sent, rather
  than what the test assumes it sent.
  """

  @doc """
  The `Prefer` header among `headers`, or `nil` when none was sent.
  """
  @spec prefer([{String.t(), String.t()}]) :: String.t() | nil
  def prefer(headers) do
    Enum.find_value(headers, fn
      {"Prefer", value} -> value
      _other -> nil
    end)
  end

  @doc """
  A body stored as `html`, as Graph reads it for a request with `headers`:
  flattened to text when the request prefers text bodies, else as HTML.
  """
  @spec read_body(String.t(), [{String.t(), String.t()}]) :: map()
  def read_body(html, headers) do
    if (prefer(headers) || "") =~ ~s(outlook.body-content-type="text"),
      do: %{"contentType" => "text", "content" => flatten(html)},
      else: %{"contentType" => "html", "content" => html}
  end

  @doc """
  `event` as Graph expands it into `exceptionOccurrences` for the request
  to `url`: its `id` and only the fields the query's `$select` names.
  """
  @spec selected(map(), String.t()) :: map()
  def selected(event, url) do
    fields =
      url
      |> URI.parse()
      |> Map.get(:query)
      |> Kernel.||("")
      |> URI.decode_query()
      |> Map.get("$select", "")
      |> String.split(",")

    Map.take(event, ["id" | fields])
  end

  defp flatten(html), do: html |> String.replace(~r/<[^>]*>/, "") |> String.trim()
end
