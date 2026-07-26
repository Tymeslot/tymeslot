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
  (`:max_participants`, `:requires_account`).

  ## Universal versus optional keys

  `universal_keys/0` must be answered by every provider — these are the ones
  that drive provider selection, and an absent key there is the drift bug this
  module exists to prevent. `optional_keys/0` are declared by some providers
  only; they are part of the closed vocabulary (so they cannot be misspelt) but
  are not required, because filling them in for the remaining providers is a
  product question rather than a mechanical one.
  """

  @universal_keys [
    :breakout_rooms,
    :chat,
    :dial_in,
    :max_participants,
    :recording,
    :screen_sharing,
    :waiting_room
  ]

  @optional_keys [
    :custom_branding,
    :end_to_end_encryption,
    :instant_meetings,
    :is_custom_provider,
    :live_streaming,
    :recurring_meetings,
    :requires_account,
    :requires_download,
    :requires_work_account,
    :scheduled_meetings
  ]

  @known_keys Enum.sort(@universal_keys ++ @optional_keys)

  @type key :: atom()
  @type value :: boolean() | non_neg_integer() | nil
  @type t :: %{optional(key()) => value()}

  @doc """
  Keys every provider must declare.
  """
  @spec universal_keys() :: [key()]
  def universal_keys, do: @universal_keys

  @doc """
  Keys a provider may declare in addition to `universal_keys/0`.
  """
  @spec optional_keys() :: [key()]
  def optional_keys, do: @optional_keys

  @doc """
  The whole permitted vocabulary, sorted.
  """
  @spec known_keys() :: [key()]
  def known_keys, do: @known_keys

  @doc """
  Builds a provider capability map, raising on anything outside the contract.

  Raises `ArgumentError` when a key is repeated, when a key is not in
  `known_keys/0`, or when one of `universal_keys/0` is missing.
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
    case @universal_keys -- keys do
      [] -> attrs
      missing -> raise ArgumentError, "missing video capability keys: #{inspect(missing)}"
    end
  end
end
