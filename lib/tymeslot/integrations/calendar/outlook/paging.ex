defmodule Tymeslot.Integrations.Calendar.Outlook.Paging do
  @moduledoc """
  Every multi-page Microsoft Graph read: a list (`calendarView`, the calendar
  list) followed through `@odata.nextLink`, and a delta query followed to its
  `@odata.deltaLink`.

  A link Graph hands back is followed exactly as it came, never decoded and
  re-encoded: `URI.encode_query/1` turns `$deltatoken` into `%24deltatoken`,
  which Graph rejects. The only change made to one is dropping the query
  parameters Graph refuses on a delta resource, which older stored links may
  carry; that is done on the raw query string.

  One page cap and one error answer every read: past `@max_pages` pages the
  read fails with `{:error, :too_many_pages, message}` rather than answering
  part of a calendar, since a missing page of busy events offers bookings over
  real conflicts and a delta stopped part-way never yields its next link.

  A delta read asks for `@delta_page_size` events a page (`odata.maxpagesize`)
  rather than leaving the size to Graph, so how far the cap reaches does not
  depend on a default Graph may change.
  """

  alias Tymeslot.Integrations.Calendar.HTTP
  alias Tymeslot.Integrations.Calendar.Outlook.GraphStatus
  alias Tymeslot.Integrations.Calendar.Shared.ApiResponse

  @graph_host "https://graph.microsoft.com"
  @api_root "/v1.0"

  @max_pages 100
  @delta_page_size 500

  # Graph refuses these on the `calendarView/delta` change-tracking resource
  # with HTTP 400 `ErrorInvalidUrlQuery`.
  @unsupported_delta_params ~w($orderby $filter $select $expand $search)

  @typedoc "A Graph client error: an error type and its message."
  @type api_error :: {:error, atom(), String.t()}

  @doc """
  Reads every page of the list at `path` with the query `params`.
  """
  @spec list_all(String.t(), String.t(), map()) :: {:ok, [map()]} | api_error()
  def list_all(token, path, params) do
    with {:ok, first} <- get(token, url(path, params), :list) do
      follow(first, token, :list, [], 1)
    end
  end

  @doc """
  Reads a delta query to its end: from `{:start, path, params}`, the first
  request of a new delta, or from `{:link, url}`, a stored delta link.

  Answers the changed events and the delta link to store, which is `nil`
  when Graph ends the read without one; `{:error, :delta_link_expired,
  message}` when Graph no longer honours the link.
  """
  @spec delta_all(String.t(), {:start, String.t(), map()} | {:link, String.t()}) ::
          {:ok, [map()], String.t() | nil} | api_error()
  def delta_all(token, {:start, path, params}), do: delta_from(token, url(path, params))
  def delta_all(token, {:link, link}), do: delta_from(token, link)

  defp delta_from(token, link) do
    with {:ok, first} <- get(token, without_unsupported_params(link), :delta) do
      follow(first, token, :delta, [], 1)
    end
  end

  defp follow(page, token, kind, pages, count) do
    pages = [page["value"] || [] | pages]

    case {kind, page["@odata.deltaLink"], page["@odata.nextLink"]} do
      {:delta, delta_link, _next} when is_binary(delta_link) ->
        {:ok, collect(pages), delta_link}

      {_kind, _delta_link, next} when is_binary(next) and count >= @max_pages ->
        {:error, :too_many_pages, "Graph read exceeded #{@max_pages} pages"}

      {_kind, _delta_link, next} when is_binary(next) ->
        link = if kind == :delta, do: without_unsupported_params(next), else: next

        with {:ok, next_page} <- get(token, link, kind) do
          follow(next_page, token, kind, pages, count + 1)
        end

      {:list, _delta_link, _next} ->
        {:ok, collect(pages)}

      {:delta, _delta_link, _next} ->
        {:ok, collect(pages), nil}
    end
  end

  defp collect(pages), do: pages |> Enum.reverse() |> Enum.concat()

  # The Prefer header is not part of a link and is sent again with every
  # page, so later pages come back in UTC with plain-text bodies like the
  # first.
  defp get(token, link, kind) do
    uri = URI.parse(link)
    path_and_query = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

    HTTP.request(:get, @graph_host, path_and_query, token,
      headers: [{"Content-Type", "application/json"}, {"Prefer", preference(kind)}],
      response_handler: &handle(&1, kind)
    )
  end

  defp preference(:list), do: ~s(outlook.timezone="UTC", outlook.body-content-type="text")

  defp preference(:delta),
    do: preference(:list) <> ", odata.maxpagesize=#{@delta_page_size}"

  # 410 Gone on a delta read is Graph's signal that the link is no longer
  # valid and the caller must bootstrap again.
  defp handle({:ok, %{status: 410}}, :delta),
    do: {:error, :delta_link_expired, "Delta link expired"}

  defp handle(response, _kind),
    do: ApiResponse.handle(response, label: "Outlook Calendar", custom: &GraphStatus.classify/1)

  defp url(path, params) when params == %{}, do: @graph_host <> @api_root <> path

  # A first request's query is built as every other Graph request's is
  # (`HTTP.request/5`); only the links Graph returns are kept as they are.
  defp url(path, params), do: @graph_host <> @api_root <> path <> "?" <> URI.encode_query(params)

  defp without_unsupported_params(link) do
    uri = URI.parse(link)

    case uri.query do
      query when query in [nil, ""] ->
        link

      query ->
        kept =
          query
          |> String.split("&")
          |> Enum.reject(&(param_name(&1) in @unsupported_delta_params))

        URI.to_string(%{uri | query: if(kept == [], do: nil, else: Enum.join(kept, "&"))})
    end
  end

  defp param_name(part), do: part |> String.split("=", parts: 2) |> hd() |> String.downcase()
end
