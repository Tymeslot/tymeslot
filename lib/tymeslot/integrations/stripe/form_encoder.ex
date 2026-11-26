defmodule Tymeslot.Integrations.Stripe.FormEncoder do
  @moduledoc """
  Encodes request parameters as a Stripe `application/x-www-form-urlencoded` body.

  Nested maps and keyword lists are bracketed (`a[b]=1`), other lists are indexed
  (`expand[0]=charge`), `nil` becomes an empty value (which Stripe reads as "unset"),
  and empty lists and maps produce no pair. Keys keep enumeration order. Values the
  encoding cannot represent (structs, tuples, pids) raise `ArgumentError` naming the
  key path, since a silently wrong body on the payment path is worse than a crash.
  """

  @doc "Encodes `params` (a map or keyword list) as a form body."
  @spec encode(map() | keyword()) :: String.t()
  def encode(params) when is_map(params) do
    params |> flatten(nil) |> URI.encode_query()
  end

  def encode(params) when is_list(params) do
    if Keyword.keyword?(params) do
      params |> flatten(nil) |> URI.encode_query()
    else
      raise ArgumentError, "expected a map or keyword list, got: #{inspect(params)}"
    end
  end

  defp flatten(%{__struct__: _module} = struct, path), do: unsupported(struct, path)

  defp flatten(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> flatten(value, join(path, key)) end)
  end

  defp flatten(list, path) when is_list(list) do
    if Keyword.keyword?(list) do
      Enum.flat_map(list, fn {key, value} -> flatten(value, join(path, key)) end)
    else
      list
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} -> flatten(value, join(path, index)) end)
    end
  end

  defp flatten(value, path) when is_binary(value) or is_atom(value) or is_number(value) do
    [{path, to_string(value)}]
  end

  defp flatten(value, path), do: unsupported(value, path)

  defp join(nil, key), do: to_string(key)
  defp join(path, key), do: "#{path}[#{key}]"

  @spec unsupported(term(), String.t() | nil) :: no_return()
  defp unsupported(value, path) do
    raise ArgumentError,
          "cannot form-encode #{inspect(value)} at #{inspect(path)}"
  end
end
