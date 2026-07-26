defmodule Tymeslot.Integrations.Video.Providers.Capabilities do
  @moduledoc """
  The declared capability vocabulary shared by every video provider.

  `ProviderRegistry.providers_with_capability/1` looks capabilities up with a
  plain `Map.get(capabilities, capability, false)`, so a provider that spells a
  key differently from its siblings is indistinguishable from a provider that
  does not support the feature at all. Providers therefore build their map with
  `new!/1`, which is evaluated at compile time from a module attribute and
  raises on an unknown or missing key. A re-introduced `supports_` prefix, a
  typo, or a dropped universal key fails the build instead of silently
  under-reporting at runtime.

  ## Naming

  Keys are bare feature names (`:recording`, not `:supports_recording`). The
  lookup reads as `providers_with_capability(:recording)`; the prefix only
  repeats the word "capability" already present at every call site. Keys that
  are genuinely not "does it support X" questions keep their natural name
  (`:max_participants`).

  ## Every key is answered by every provider

  There is deliberately no optional tier. A key only some providers declare
  under-reports exactly like a misspelt one: `providers_with_capability/1`
  cannot tell "this provider says no" from "this provider never said", so the
  drift this module exists to prevent would simply move from spelling to
  coverage. Requiring every key of every provider makes both impossible.

  The practical consequence is that adding a capability means answering it for
  all five providers. That is the point: if a fact cannot be established for
  every provider, a lookup over it cannot give a trustworthy answer, and the
  key should wait until it can.
  """

  @known_keys [
    :breakout_rooms,
    :chat,
    :dial_in,
    :max_participants,
    :recording,
    :screen_sharing,
    :waiting_room
  ]

  @type key :: atom()
  @type value :: boolean() | non_neg_integer() | nil
  @type t :: %{optional(key()) => value()}

  @doc """
  The whole vocabulary. Every provider must answer every one of these.
  """
  @spec known_keys() :: [key()]
  def known_keys, do: @known_keys

  @doc """
  Builds a provider capability map, raising on anything outside the contract.

  Raises `ArgumentError` when a key is repeated, when a key is not in
  `known_keys/0`, or when one of them is missing.
  """
  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    keys = Keyword.keys(attrs)

    attrs
    |> check_duplicates(keys)
    |> check_unknown(keys)
    |> check_missing(keys)
    |> Map.new()
  end

  defp check_duplicates(attrs, keys) do
    case keys -- Enum.uniq(keys) do
      [] -> attrs
      dupes -> raise ArgumentError, "duplicate video capability keys: #{inspect(dupes)}"
    end
  end

  defp check_unknown(attrs, keys) do
    case keys -- @known_keys do
      [] ->
        attrs

      unknown ->
        raise ArgumentError,
              "unknown video capability keys: #{inspect(unknown)}. " <>
                "Known keys: #{inspect(@known_keys)}"
    end
  end

  defp check_missing(attrs, keys) do
    case @known_keys -- keys do
      [] -> attrs
      missing -> raise ArgumentError, "missing video capability keys: #{inspect(missing)}"
    end
  end
end
