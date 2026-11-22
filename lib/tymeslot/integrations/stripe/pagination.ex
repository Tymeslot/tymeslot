defmodule Tymeslot.Integrations.Stripe.Pagination do
  @moduledoc """
  Walks a Stripe list endpoint page by page with `starting_after`.

  `list_fun` is a two-arity resource function such as
  `&Tymeslot.Integrations.Stripe.Charges.list/2`. Params may use atom or
  string keys. `limit` defaults to 100 unless the caller sets one, and a
  caller's `starting_after` is where the walk begins.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Error

  @default_limit 100

  @type list_fun :: (map(), keyword() -> Client.result())

  @doc """
  A lazy stream of every object, one request per page, fetched as the stream is
  consumed. A failed page raises its `Tymeslot.Integrations.Stripe.Error` from
  inside the stream, and any other reason (such as `:missing_api_key`) raises
  `ArgumentError`; `collect/3` is the non-raising form.
  """
  @spec stream(list_fun(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream(list_fun, params, opts) do
    params = prepare(params)

    Stream.resource(
      fn -> {:more, params["starting_after"]} end,
      fn
        :done -> {:halt, :done}
        {:more, cursor} -> next_batch(list_fun, params, opts, cursor)
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Every object as `{:ok, objects}`, or the first error the list function
  returned (a `Tymeslot.Integrations.Stripe.Error` or `:missing_api_key`),
  unchanged.
  """
  @spec collect(list_fun(), map() | keyword(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t() | :missing_api_key}
  def collect(list_fun, params, opts) do
    params = prepare(params)
    collect_pages(list_fun, params, opts, params["starting_after"], [])
  end

  defp collect_pages(list_fun, params, opts, cursor, acc) do
    case page(list_fun, params, opts, cursor) do
      {:ok, data, :done} ->
        {:ok, Enum.concat(Enum.reverse(acc, [data]))}

      {:ok, data, {:more, next_cursor}} ->
        collect_pages(list_fun, params, opts, next_cursor, [data | acc])

      {:error, _reason} = error ->
        error
    end
  end

  defp next_batch(list_fun, params, opts, cursor) do
    case page(list_fun, params, opts, cursor) do
      {:ok, data, next} -> {data, next}
      {:error, %Error{} = error} -> raise error
      {:error, reason} -> raise ArgumentError, "Stripe list failed: #{inspect(reason)}"
    end
  end

  defp page(list_fun, params, opts, cursor) do
    case list_fun.(with_cursor(params, cursor), opts) do
      {:ok, %{"data" => data} = body} when is_list(data) -> {:ok, data, next(body, data)}
      {:ok, _body} -> raise ArgumentError, "Stripe list response has no \"data\" list"
      {:error, _reason} = error -> error
    end
  end

  defp prepare(params) do
    params
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("limit", @default_limit)
  end

  defp with_cursor(params, nil), do: params
  defp with_cursor(params, cursor), do: Map.put(params, "starting_after", cursor)

  defp next(%{"has_more" => true}, [_first | _rest] = data), do: {:more, List.last(data)["id"]}
  defp next(_body, _data), do: :done
end
