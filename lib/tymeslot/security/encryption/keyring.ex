defmodule Tymeslot.Security.Encryption.Keyring do
  @moduledoc """
  Builds the data-at-rest keyring from configuration.

  Three settings feed it, all under `config :tymeslot, Tymeslot.Security.Encryption`
  (filled from the environment by `config/runtime.exs`):

    * `:data_encryption_keys` (`DATA_ENCRYPTION_KEYS`): an ordered list of
      `id:base64` entries, for example `"2:<new>,1:<old>"`. Ids run from 1 to
      255 and are the version byte stamped on every value a key writes, so an id
      must never be reused for a different key. The **first entry is the
      primary**, the key every new value is written with; the others stay
      readable. Listing a new key second makes it readable everywhere before
      any node writes with it, which is what a rolling rotation needs.
    * `:data_encryption_key` (`DATA_ENCRYPTION_KEY`): the single key every
      install used before the list existed. It is always key 1, merged into
      the list, and is the primary when no list is set. A list entry `1:` with
      a different key is refused, since the same version byte cannot name two
      keys.
    * `:legacy_key_retired` (`LEGACY_KEY_RETIRED`): stops deriving the v0
      legacy key from `SECRET_KEY_BASE`. Values still written under it become
      unreadable (never altered) until the flag is unset.

  With no versioned key at all, the primary is the legacy key (version 0), which
  is how an install that never set `DATA_ENCRYPTION_KEY` keeps working.

  Every key is the SHA-256 of at least 32 decoded bytes. A configuration that
  cannot work raises `ConfigError`, naming what is wrong and how to fix it;
  errors never include key material.
  """

  alias Tymeslot.Security.Encryption.ConfigError

  @legacy_version 0
  @aad "Tymeslot.Encryption"
  @min_key_bytes 32
  @min_secret_key_base_bytes 64

  @generate_key "Generate a new one with `openssl rand -base64 48 | tr -d '\\n'`; " <>
                  "no credential can have been stored under a key that cannot be read, " <>
                  "so replacing it loses nothing"

  @type t :: %{
          current_version: 0..255,
          keys: %{optional(1..255) => binary()},
          legacy_key: binary() | nil
        }

  @doc false
  # The AEAD associated data, also the salt of the legacy key derivation.
  @spec aad() :: String.t()
  def aad, do: @aad

  @doc """
  Builds the keyring from the current application config, raising
  `ConfigError` when the configuration cannot work.
  """
  @spec build!() :: t()
  def build! do
    config = Application.get_env(:tymeslot, Tymeslot.Security.Encryption, [])
    entries = list_entries(config[:data_encryption_keys])
    single = single_key(config[:data_encryption_key])
    keys = merge_single_key(Map.new(entries), single)
    current_version = current_version(entries, single)
    retired? = config[:legacy_key_retired] == true

    if retired? and current_version == @legacy_version do
      raise ConfigError,
        reason:
          "LEGACY_KEY_RETIRED is set but no DATA_ENCRYPTION_KEY or DATA_ENCRYPTION_KEYS " <>
            "is configured, so there is no key to write with",
        fix: "Configure a data encryption key, or unset LEGACY_KEY_RETIRED"
    end

    %{
      current_version: current_version,
      keys: keys,
      legacy_key: if(retired?, do: nil, else: legacy_key())
    }
  end

  defp current_version([{id, _key} | _rest], _single), do: id
  defp current_version([], nil), do: @legacy_version
  defp current_version([], _single), do: 1

  defp merge_single_key(keys, nil), do: keys

  defp merge_single_key(keys, single) do
    case Map.fetch(keys, 1) do
      :error ->
        Map.put(keys, 1, single)

      {:ok, ^single} ->
        keys

      {:ok, _other} ->
        raise ConfigError,
          reason:
            "DATA_ENCRYPTION_KEY is key 1, but DATA_ENCRYPTION_KEYS lists a different " <>
              "key under id 1",
          fix:
            "Use the DATA_ENCRYPTION_KEY value for the 1: entry, or give the other key a new id"
    end
  end

  defp single_key(nil), do: nil

  defp single_key(encoded) do
    case String.trim(encoded) do
      "" -> nil
      trimmed -> derive!(trimmed, "DATA_ENCRYPTION_KEY")
    end
  end

  defp list_entries(nil), do: []

  defp list_entries(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.map(&parse_entry!/1)
    |> reject_duplicate_ids!()
  end

  defp parse_entry!({entry, position}) do
    label = "DATA_ENCRYPTION_KEYS entry #{position}"

    with [id, encoded] <- String.split(entry, ":", parts: 2),
         {id, ""} when id in 1..255 <- Integer.parse(String.trim(id)) do
      {id, derive!(String.trim(encoded), label)}
    else
      _invalid ->
        raise ConfigError,
          reason: "#{label} must be `<id>:<base64 key>` with an id from 1 to 255",
          fix: "Separate entries with commas, for example `2:<new key>,1:<current key>`"
    end
  end

  defp reject_duplicate_ids!(entries) do
    case entries |> Enum.frequencies_by(&elem(&1, 0)) |> Enum.find(&(elem(&1, 1) > 1)) do
      nil ->
        entries

      {id, _count} ->
        raise ConfigError,
          reason: "DATA_ENCRYPTION_KEYS lists id #{id} more than once",
          fix: "Give every key its own id, and never reuse an id for a different key"
    end
  end

  defp derive!(encoded, label) do
    case Base.decode64(encoded) do
      {:ok, raw} when byte_size(raw) >= @min_key_bytes ->
        :crypto.hash(:sha256, raw)

      {:ok, raw} ->
        raise ConfigError,
          reason:
            "#{label} must decode to at least #{@min_key_bytes} bytes of entropy, " <>
              "got #{byte_size(raw)}",
          fix: @generate_key

      :error ->
        raise ConfigError,
          reason: "#{label} must be valid Base64",
          fix:
            "Use standard Base64 with `=` padding; URL-safe characters (`-`, `_`) are " <>
              "refused. " <> @generate_key
    end
  end

  defp legacy_key do
    secret_base = Application.get_env(:tymeslot, TymeslotWeb.Endpoint)[:secret_key_base]

    if is_nil(secret_base) or byte_size(secret_base) < @min_secret_key_base_bytes do
      raise ConfigError,
        reason:
          "SECRET_KEY_BASE must be at least #{@min_secret_key_base_bytes} bytes to derive " <>
            "the legacy encryption key",
        fix:
          "Replace it with a value from `openssl rand -base64 64 | tr -d '\\n'`, which " <>
            "signs every user out once"
    end

    :crypto.hash(:sha256, secret_base <> @aad)
  end
end
