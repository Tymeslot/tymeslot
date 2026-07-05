defmodule Tymeslot.Security.Encryption do
  @moduledoc """
  Encrypts and decrypts sensitive credentials at rest using AES-256-GCM.

  ## Versioned keyring

  Every ciphertext is self-describing: values written by the current code carry a
  one-byte version prefix identifying the key that produced them, so several keys
  can coexist and data can be rotated from one key to another without downtime.

    * **v0 (legacy)** — the historical format: `nonce <> tag <> ciphertext` with no
      version prefix, encrypted under a key *derived from* `SECRET_KEY_BASE`. This
      welded data-at-rest protection to the cookie-signing secret. The legacy key
      stays available for decrypt-only so existing values keep opening.
    * **v1 (primary)** — `<<1>> <> nonce <> tag <> ciphertext`, encrypted under the
      dedicated `DATA_ENCRYPTION_KEY`. This is what new writes use once the key is
      configured.

  Rotating to a future key is a one-line addition (`@current_version` bump plus a
  keyring entry) followed by a re-encryption sweep — never a wipe.

  ## Graceful rollout

  When `DATA_ENCRYPTION_KEY` is absent the keyring falls back to writing the legacy
  v0 format, so deploying this code with no environment change preserves the exact
  previous behaviour. Setting the key flips new writes to v1; running the
  re-encryption sweep (`mix tymeslot.reencrypt_credentials` from a source install,
  or `Tymeslot.Security.CredentialReencryption.run/0` via `bin/tymeslot eval` for a
  release — see README) then migrates existing v0 values to v1. Only a
  *malformed* key raises — an absent one is treated as "not opted in yet".

  ## Failure surface

  `decrypt/1` raises when a value cannot be decrypted (corrupt, tampered, or
  encrypted under a key that is no longer available). `decrypt_with_status/1`
  surfaces the same failure as `{:error, :requires_reencryption}` for callers that
  need to react — for example, calendar sync workers flag the affected integration
  for reauthentication instead of crashing.
  """

  @aad "Tymeslot.Encryption"

  @legacy_version 0
  @current_version 1

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
  @spec decrypt_with_status(nil) :: {:ok, nil}
  def decrypt_with_status(nil), do: {:ok, nil}

  @spec decrypt_with_status(binary()) ::
          {:ok, binary() | nil} | {:error, :requires_reencryption}
  def decrypt_with_status(
        <<version, nonce::binary-size(@nonce_size), tag::binary-size(@tag_size),
          ciphertext::binary>> = encrypted
      )
      when byte_size(encrypted) >= @versioned_min_size do
    %{keys: keys, legacy_key: legacy_key} = keyring()

    case Map.get(keys, version) do
      nil ->
        # The version byte is not a live key id — the bytes are a prefix-less
        # legacy value. Re-interpret the whole binary under the legacy key.
        legacy_decrypt(encrypted, legacy_key)

      key ->
        case aead_decrypt(key, nonce, tag, ciphertext) do
          {:ok, plaintext} ->
            {:ok, plaintext}

          :error ->
            # The version byte collided with a live key id but verification
            # failed — the bytes may still be a legacy value. Retry legacy.
            legacy_decrypt(encrypted, legacy_key)
        end
    end
  end

  def decrypt_with_status(encrypted)
      when is_binary(encrypted) and byte_size(encrypted) >= @legacy_min_size do
    %{legacy_key: legacy_key} = keyring()
    legacy_decrypt(encrypted, legacy_key)
  end

  def decrypt_with_status(_value), do: {:ok, nil}

  @doc """
  Returns `true` when a stored value is already written under the current primary
  version, i.e. the re-encryption sweep has nothing to do for it.

  A value counts as current only when its version prefix matches the primary *and*
  it verifies under the primary key, so a legacy blob whose leading nonce byte
  coincides with the primary version id is never mistaken for migrated data.
  """
  @spec current?(binary()) :: boolean()
  def current?(
        <<version, nonce::binary-size(@nonce_size), tag::binary-size(@tag_size),
          ciphertext::binary>> = encrypted
      )
      when byte_size(encrypted) >= @versioned_min_size do
    %{current_version: current_version, keys: keys} = keyring()

    case Map.get(keys, version) do
      nil ->
        false

      key ->
        version == current_version and
          match?({:ok, _plaintext}, aead_decrypt(key, nonce, tag, ciphertext))
    end
  end

  def current?(_value), do: false

  @doc """
  The primary key version new writes are stamped with. `0` means no dedicated
  `DATA_ENCRYPTION_KEY` is configured and writes still use the legacy format.
  """
  @spec current_version() :: non_neg_integer()
  def current_version, do: keyring().current_version

  @doc """
  Generates a new random API key.
  """
  @spec generate_api_key() :: String.t()
  def generate_api_key do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc false
  # Internal helper: encrypt a value under the legacy (v0) key in the prefix-less
  # format. Used by the sweep's tests and any tooling that must materialise legacy
  # ciphertext. Never used for production writes — `encrypt/1` is the write path.
  @spec encrypt_legacy(binary()) :: binary()
  def encrypt_legacy(plaintext) when is_binary(plaintext) do
    %{legacy_key: legacy_key} = keyring()
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, legacy_key, nonce, plaintext, @aad, true)

    nonce <> tag <> ciphertext
  end

  @doc false
  # Drops the cached keyring so the next call rebuilds it from current config.
  # Only meaningful in tests that swap `DATA_ENCRYPTION_KEY` at runtime.
  @spec reset_keyring() :: :ok
  def reset_keyring do
    :persistent_term.erase({__MODULE__, :keyring})
    :ok
  end

  # Private functions

  defp aead_decrypt(key, nonce, tag, ciphertext) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @aad, tag, false) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  defp legacy_decrypt(
         <<nonce::binary-size(@nonce_size), tag::binary-size(@tag_size), ciphertext::binary>>,
         key
       ) do
    case aead_decrypt(key, nonce, tag, ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> {:error, :requires_reencryption}
    end
  end

  defp legacy_decrypt(_value, _key), do: {:ok, nil}

  defp keyring do
    case :persistent_term.get({__MODULE__, :keyring}, nil) do
      nil ->
        built = build_keyring()
        :persistent_term.put({__MODULE__, :keyring}, built)
        built

      built ->
        built
    end
  end

  defp build_keyring do
    legacy_key = legacy_key()

    case data_key() do
      nil ->
        # No dedicated key configured — behave exactly as before: read and write
        # the legacy v0 format derived from SECRET_KEY_BASE.
        %{current_version: @legacy_version, keys: %{}, legacy_key: legacy_key}

      key ->
        %{
          current_version: @current_version,
          keys: %{@current_version => key},
          legacy_key: legacy_key
        }
    end
  end

  defp legacy_key do
    secret_base = Application.get_env(:tymeslot, TymeslotWeb.Endpoint)[:secret_key_base]

    if is_nil(secret_base) or byte_size(secret_base) < 64 do
      raise "SECRET_KEY_BASE must be at least 64 bytes for secure encryption"
    end

    :crypto.hash(:sha256, secret_base <> @aad)
  end

  defp data_key do
    case Application.get_env(:tymeslot, __MODULE__)[:data_encryption_key] do
      nil -> nil
      encoded -> encoded |> String.trim() |> trimmed_data_key()
    end
  end

  defp trimmed_data_key(""), do: nil
  defp trimmed_data_key(trimmed), do: derive_data_key(trimmed)

  defp derive_data_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, raw} when byte_size(raw) >= 32 ->
        :crypto.hash(:sha256, raw)

      {:ok, raw} ->
        raise "DATA_ENCRYPTION_KEY must decode to at least 32 bytes of entropy, got #{byte_size(raw)}"

      :error ->
        raise "DATA_ENCRYPTION_KEY must be valid Base64"
    end
  end
end
