defmodule Tymeslot.StripeFixtures do
  @moduledoc """
  Stripe API objects and error bodies as Stripe returns them at the pinned API
  version (`2025-11-17.clover`), read from
  `fixtures/stripe/api/2025-11-17.clover/`. That folder's README records where
  each file came from.

  Every value is string-keyed, as `Tymeslot.Integrations.Stripe` returns it.
  Overrides are string-keyed too: an atom key raises, since it would add a key
  the code under test never reads.
  """

  @fixtures_dir Path.expand("fixtures/stripe/api/2025-11-17.clover", __DIR__)

  @doc """
  Returns the named object (`"refund"` loads `refund.json`) with `overrides`
  deep-merged in: a map value merges into the map it meets, any other value
  (including `nil` and lists) replaces it.
  """
  @spec object(String.t(), map()) :: map()
  def object(name, overrides \\ %{}) do
    @fixtures_dir |> Path.join(name <> ".json") |> read!() |> merge!(overrides)
  end

  @doc """
  Wraps `objects` in a Stripe list object. Options: `:has_more` (default
  `false`) and `:url` (default `"/v1/list"`).
  """
  @spec list([map()], keyword()) :: map()
  def list(objects, opts \\ []) do
    %{
      "object" => "list",
      "data" => objects,
      "has_more" => Keyword.get(opts, :has_more, false),
      "url" => Keyword.get(opts, :url, "/v1/list")
    }
  end

  @doc """
  Returns `{status, body}` for the named error (`errors/<name>.json`), with
  `overrides` merged into `body["error"]`.
  """
  @spec error_body(String.t(), map()) :: {pos_integer(), map()}
  def error_body(name, overrides \\ %{}) do
    %{"status" => status, "body" => body} =
      @fixtures_dir |> Path.join("errors/#{name}.json") |> read!()

    {status, Map.update!(body, "error", &merge!(&1, overrides))}
  end

  @doc """
  Removes the key at `path` (a list of string keys), for a field Stripe omits
  in some responses.
  """
  @spec without(map(), [String.t(), ...]) :: map()
  def without(map, [key]), do: Map.delete(map, key)
  def without(map, [key | rest]), do: Map.update!(map, key, &without(&1, rest))

  defp read!(path), do: path |> File.read!() |> Jason.decode!()

  defp merge!(base, overrides) do
    string_keyed!(overrides)
    deep_merge(base, overrides)
  end

  defp deep_merge(base, overrides) do
    Map.merge(base, overrides, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  # Checks the whole override tree, so an atom key inside a value that
  # replaces rather than merges is caught too.
  defp string_keyed!(%{} = map) do
    Enum.each(map, fn
      {key, _value} when is_atom(key) ->
        raise ArgumentError,
              "Stripe fixture overrides must use string keys, got #{inspect(key)}"

      {_key, value} ->
        string_keyed!(value)
    end)
  end

  defp string_keyed!(list) when is_list(list), do: Enum.each(list, &string_keyed!/1)
  defp string_keyed!(_value), do: :ok
end
