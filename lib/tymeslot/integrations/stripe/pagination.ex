defmodule Tymeslot.Integrations.Stripe.Pagination do
  @moduledoc """
  Walks a Stripe list endpoint page by page with `starting_after`.

  `list_fun` is a two-arity resource function such as
  `&Tymeslot.Integrations.Stripe.Charges.list/2`. `limit` defaults to 100
  unless the caller sets one.
  """

  alias Tymeslot.Integrations.Stripe.Error

  @default_limit 100

  @doc """
  A lazy stream of every object, one request per page, fetched as the stream is
  consumed. A failed page raises its `Tymeslot.Integrations.Stripe.Error` from
  inside the stream, and any other reason (such as `:missing_api_key`) raises
  `ArgumentError`; `collect/3` is the non-raising form.
  """
  @spec stream((map(), keyword() -> {:ok, map()} | {:error, term()}), map(), keyword()) ::
          Enumerable.t()
  def stream(list_fun, params, opts) do
    params = Map.put_new(Map.new(params), :limit, @default_limit)

    Stream.resource(
      fn -> {:more, nil} end,
      fn
        :done -> {:halt, :done}
        {:more, cursor} -> fetch(list_fun, params, opts, cursor)
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Every object as `{:ok, objects}`, or `{:error, error}` for the first failed
  page; `{:error, :missing_api_key}` when no key is configured.
  """
  @spec collect((map(), keyword() -> {:ok, map()} | {:error, term()}), map(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t() | :missing_api_key}
  def collect(list_fun, params, opts) do
    {:ok, list_fun |> throwing_missing_key() |> stream(params, opts) |> Enum.to_list()}
  rescue
    error in Error -> {:error, error}
  catch
    :missing_api_key -> {:error, :missing_api_key}
  end

  defp throwing_missing_key(list_fun) do
    fn params, opts ->
      case list_fun.(params, opts) do
        {:error, :missing_api_key} -> throw(:missing_api_key)
        result -> result
      end
    end
  end

  defp fetch(list_fun, params, opts, cursor) do
    case list_fun.(with_cursor(params, cursor), opts) do
      {:ok, %{"data" => data} = page} -> {data, next(page, data)}
      {:error, %Error{} = error} -> raise error
      {:error, reason} -> raise ArgumentError, "Stripe list failed: #{inspect(reason)}"
    end
  end

  defp with_cursor(params, nil), do: params
  defp with_cursor(params, cursor), do: Map.put(params, :starting_after, cursor)

  defp next(%{"has_more" => true}, [_first | _rest] = data), do: {:more, List.last(data)["id"]}
  defp next(_page, _data), do: :done
end
