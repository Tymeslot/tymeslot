defmodule Tymeslot.Security.Encryption do
  @moduledoc """
  Encrypts and decrypts sensitive credentials at rest using AES-256-GCM.

  ## Versioned keyring

  Every ciphertext is self-describing: values written by the current code carry a
  one-byte version prefix identifying the key that produced them, so several keys
  can coexist and data can be rotated from one key to another without downtime.

    * **v0 (legacy)**: the historical format, `nonce <> tag <> ciphertext` with no
      version prefix, encrypted under a key *derived from* `SECRET_KEY_BASE`. It
      stays readable until the operator sets `LEGACY_KEY_RETIRED`.
    * **v1 to v255**: `<<version>> <> nonce <> tag <> ciphertext`, encrypted under
      the key with that id in `DATA_ENCRYPTION_KEYS`, or under
      `DATA_ENCRYPTION_KEY`, which is always key 1.

  `Tymeslot.Security.Encryption.Keyring` builds the keyring from configuration
  and documents the settings. New writes use the primary key; every other
  configured key stays readable. Rotating is a configuration change followed by
  the re-encryption sweep (`Tymeslot.Security.CredentialReencryption`), never a
  wipe: the README's "Data-at-rest encryption" section has the procedure.

  ## Graceful rollout

  With no versioned key configured the keyring writes the legacy v0 format, so an
  install that never set `DATA_ENCRYPTION_KEY` keeps its exact previous
  behaviour, and one with a single `DATA_ENCRYPTION_KEY` keeps writing v1. The
  keyring is built and validated at boot (`validate!/0`), so a malformed key or
  an impossible combination stops the application from starting rather than
  failing on the first credential it touches.

  ## Failure surface

  `decrypt/1` raises when a value cannot be decrypted (corrupt, tampered, or
  encrypted under a key that is no longer available). `decrypt_with_status/1`
  surfaces the same failure as `{:error, :requires_reencryption}` for callers that
  need to react — for example, calendar sync workers flag the affected integration
  for reauthentication instead of crashing. A value written under a key since
  dropped from the keyring is the operator's to fix, by adding the key back;
  `absent_key_version/1` tells it apart, so such an integration is reported
  rather than flagged, and the boot check names the missing ids.
  """

  require Logger

  alias Tymeslot.Security.Encryption.{ConfigError, Keyring}

  @aad Keyring.aad()

  @legacy_version 0

  @nonce_size 12
  @tag_size 16

  # Legacy v0 envelope is nonce(12) <> tag(16) <> ciphertext — 28 bytes minimum.
  @legacy_min_size @nonce_size + @tag_size
  # A versioned envelope prepends a 1-byte version — 29 bytes minimum.
  @versioned_min_size 1 + @legacy_min_size

  @doc """
  Encrypts a string value under the current primary key.

  Returns a binary envelope carrying the version prefix, nonce, GCM tag and
  ciphertext. Returns `nil` for a `nil` input.
  """
  @spec encrypt(nil) :: nil
  def encrypt(nil), do: nil

  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    %{current_version: version, keys: keys, legacy_key: legacy_key} = keyring()

    {key, prefix} =
      case version do
        @legacy_version -> {legacy_key, <<>>}
        v -> {Map.fetch!(keys, v), <<v>>}
      end

    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, @aad, true)

    prefix <> nonce <> tag <> ciphertext
  end

  @doc """
  Decrypts a value produced by `encrypt/1`.

  Raises when the ciphertext is corrupt, tampered, or encrypted under a key that
  is no longer available. Callers that need a non-raising variant should use
  `decrypt_with_status/1`.
  """
  @spec decrypt(nil) :: nil
  def decrypt(nil), do: nil

  @spec decrypt(binary()) :: binary()
  def decrypt(encrypted) when is_binary(encrypted) and byte_size(encrypted) >= @legacy_min_size do
    case decrypt_with_status(encrypted) do
      {:ok, plaintext} when is_binary(plaintext) ->
        plaintext

      {:error, :requires_reencryption} ->
        raise "Failed to decrypt data. The data may be corrupted or the key may have changed."
    end
  end

  def decrypt(_value), do: nil

  @doc """
  Decrypts a value and reports failure as a tagged tuple instead of raising.

  Returns:

    * `{:ok, binary()}` on success
    * `{:ok, nil}` when the input itself is `nil` or too short to be valid
      ciphertext (treated as "no credential stored")
    * `{:error, :requires_reencryption}` when AEAD verification fails — either the
      data was tampered with or it was encrypted under a key that is no longer
      available

  The version prefix selects the key. Legacy v0 values (no prefix) are recognised
  by falling back to the legacy key, so a byte-for-byte legacy blob whose first
  byte happens to collide with a live version id still decrypts correctly.

  Calendar and video sync workers use this to detect the failure case and flag
  affected integrations as needing reauthentication rather than crashing.
  """
  @spec decrypt_with_status(binary() | nil) ::
          {:ok, binary() | nil} | {:error, :requires_reencryption}
  def decrypt_with_status(encrypted) do
    case open(encrypted) do
      {:ok, _version, plaintext} -> {:ok, plaintext}
      :empty -> {:ok, nil}
      {:error, :requires_reencryption} = error -> error
    end
  end

  @doc """
  Reports which key version opens a stored value, without returning it.

  Returns `{:ok, version}` (`0` for the legacy key), `:empty` for `nil` or a
  value too short to be ciphertext, or `{:error, :requires_reencryption}` when
  no configured key opens it. The key report and the re-encryption sweep use
  it to tell the operator what each key still holds.
  """
  @spec key_version(binary() | nil) ::
          {:ok, non_neg_integer()} | :empty | {:error, :requires_reencryption}
  def key_version(encrypted) do
    case open(encrypted) do
      {:ok, version, _plaintext} -> {:ok, version}
      other -> other
    end
  end

  @doc """
  Names the key a value was written under when that key is missing from the
  keyring: an operator's configuration mistake, recovered by adding the key
  back, rather than a credential that is gone.

  Returns `{:ok, id}` when no configured key opens the value and its version
  prefix names a key id that is not configured but plausibly was: one below
  the highest configured id, since ids are allocated upwards and a dropped
  one sits below the key that replaced it, or id 1, the
  `DATA_ENCRYPTION_KEY` slot. Returns `:error` for a value that opens, an
  empty one, and one no id accounts for (corrupt, or on the legacy key).

  The prefix of a legacy v0 value is a random nonce byte, so the attribution
  is a strong hint rather than proof: bounding the ids it accepts keeps a v0
  value from being taken for one under an arbitrary id. Its plaintext is never
  returned.
  """
  @spec absent_key_version(binary() | nil) :: {:ok, 1..255} | :error
  def absent_key_version(encrypted) do
    with {:error, :requires_reencryption} <- open(encrypted),
         <<version, _rest::binary>> when byte_size(encrypted) >= @versioned_min_size <-
           encrypted,
         true <- absent_id?(version, keyring().keys) do
      {:ok, version}
    else
      _opens_or_unattributable -> :error
    end
  end

  @doc """
  The ids of the versioned keys configured, in ascending order. Empty when
  only the legacy key is in use.
  """
  @spec configured_versions() :: [1..255]
  def configured_versions, do: keyring().keys |> Map.keys() |> Enum.sort()

  @doc """
  Returns `true` when a stored value is already written under the current primary
  version, i.e. the re-encryption sweep has nothing to do for it.

  A value counts as current only when it verifies under the primary key, so a
  legacy blob whose leading nonce byte coincides with the primary version id is
  never mistaken for migrated data.
  """
  @spec current?(binary() | nil) :: boolean()
  def current?(encrypted), do: key_version(encrypted) == {:ok, current_version()}

  @doc """
  The primary key version new writes are stamped with. `0` means no versioned
  key is configured and writes still use the legacy format.
  """
  @spec current_version() :: non_neg_integer()
  def current_version, do: keyring().current_version

  @doc """
  Builds and caches the keyring, raising `ConfigError` when the key
  configuration cannot work.
  """
  @spec validate!() :: :ok
  def validate! do
    reset_keyring()
    _keyring = keyring()
    :ok
  end

  @doc """
  The boot-time form of `validate!/0`. On a key configuration that cannot work
  it logs what is wrong and how to fix it, and returns the error so the
  application can refuse to start without burying the reason in a stack trace.
  """
  @spec check_config() :: :ok | {:error, ConfigError.t()}
  def check_config do
    validate!()
  rescue
    error in ConfigError ->
      Logger.error(
        "Tymeslot cannot start: the data encryption key configuration is invalid. " <>
          Exception.message(error) <>
          " Nothing has been read or changed; start Tymeslot again once the " <>
          "configuration is fixed. The data-at-rest encryption section of the " <>
          "installation guide explains every setting.",
        event_type: "encryption_config_invalid"
      )

      {:error, error}
  end

  @doc """
  Whether `LEGACY_KEY_RETIRED` is in effect, so v0 values no longer open.
  """
  @spec legacy_key_retired?() :: boolean()
  def legacy_key_retired?, do: is_nil(keyring().legacy_key)

  @doc false
  # Drops the cached keyring so the next call rebuilds it from current config.
  # Only meaningful in tests that swap `DATA_ENCRYPTION_KEY` at runtime.
  @spec reset_keyring() :: :ok
  def reset_keyring do
    :persistent_term.erase({__MODULE__, :keyring})
    :ok
  end

  # Private functions

  # The version prefix selects the key. A value whose prefix is not a live key
  # id, or that fails under the key it names, is retried as a prefix-less
  # legacy value, so a legacy blob whose first nonce byte collides with a live
  # version id still opens.
  defp open(
         <<version, nonce::binary-size(@nonce_size), tag::binary-size(@tag_size),
           ciphertext::binary>> = encrypted
       )
       when byte_size(encrypted) >= @versioned_min_size do
    %{keys: keys, legacy_key: legacy_key} = keyring()

    with {:ok, key} <- Map.fetch(keys, version),
         {:ok, plaintext} <- aead_decrypt(key, nonce, tag, ciphertext) do
      {:ok, version, plaintext}
    else
      _not_versioned -> legacy_open(encrypted, legacy_key)
    end
  end

  defp open(encrypted) when is_binary(encrypted) and byte_size(encrypted) >= @legacy_min_size do
    legacy_open(encrypted, keyring().legacy_key)
  end

  defp open(_value), do: :empty

  defp absent_id?(version, keys) do
    highest = keys |> Map.keys() |> Enum.max(fn -> 1 end)
    version in 1..max(highest, 1)//1 and not Map.has_key?(keys, version)
  end

  defp aead_decrypt(key, nonce, tag, ciphertext) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @aad, tag, false) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  # With the legacy key retired, a value no versioned key opens cannot be told
  # apart from a v0 value, so it is reported as unreadable and left untouched.
  defp legacy_open(_value, nil), do: {:error, :requires_reencryption}

  defp legacy_open(
         <<nonce::binary-size(@nonce_size), tag::binary-size(@tag_size), ciphertext::binary>>,
         key
       ) do
    case aead_decrypt(key, nonce, tag, ciphertext) do
      {:ok, plaintext} -> {:ok, @legacy_version, plaintext}
      :error -> {:error, :requires_reencryption}
    end
  end

  defp keyring do
    case :persistent_term.get({__MODULE__, :keyring}, nil) do
      nil ->
        built = Keyring.build!()
        :persistent_term.put({__MODULE__, :keyring}, built)
        built

      built ->
        built
    end
  end
end
