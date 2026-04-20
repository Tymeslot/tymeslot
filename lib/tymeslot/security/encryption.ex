defmodule Tymeslot.Security.Encryption do
  @moduledoc """
  Handles encryption and decryption of sensitive data in the database.
  Uses AES-256-GCM for authenticated encryption.

  `decrypt/1` raises when a value cannot be decrypted (corrupt, tampered, or
  encrypted under a key that is no longer available). `decrypt_with_status/1`
  surfaces the same failure as `{:error, :requires_reencryption}` for callers
  that need to react — for example, calendar sync workers flag the affected
  integration for reauthentication instead of crashing.
  """

  @aad "Tymeslot.Encryption"

  @doc """
  Encrypts a string value using the application's secret key.
  Returns a binary containing the nonce and ciphertext.
  """
  @spec encrypt(nil) :: nil
  def encrypt(nil), do: nil

  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    secret_key = get_secret_key()
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        secret_key,
        nonce,
        plaintext,
        @aad,
        true
      )

    nonce <> tag <> ciphertext
  end

  @doc """
  Decrypts a value that was encrypted with `encrypt/1`.

  Raises when the ciphertext is corrupt, tampered, or encrypted under a key
  that is no longer available. Callers that need a non-raising variant should
  use `decrypt_with_status/1`.
  """
  @spec decrypt(nil) :: nil
  def decrypt(nil), do: nil

  @spec decrypt(binary()) :: binary()
  def decrypt(encrypted) when is_binary(encrypted) and byte_size(encrypted) >= 28 do
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
    * `{:error, :requires_reencryption}` when AEAD verification fails — either
      the data was tampered with or it was encrypted under a different key

  Calendar sync workers use this to detect the failure case and flag affected
  integrations as needing reauthentication rather than crashing.
  """
  @spec decrypt_with_status(nil) :: {:ok, nil}
  def decrypt_with_status(nil), do: {:ok, nil}

  @spec decrypt_with_status(binary()) ::
          {:ok, binary() | nil} | {:error, :requires_reencryption}
  def decrypt_with_status(encrypted) when is_binary(encrypted) and byte_size(encrypted) >= 28 do
    <<nonce::binary-12, tag::binary-16, ciphertext::binary>> = encrypted

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           get_secret_key(),
           nonce,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      :error -> {:error, :requires_reencryption}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt_with_status(_value), do: {:ok, nil}

  @doc """
  Generates a new random API key.
  """
  @spec generate_api_key() :: String.t()
  def generate_api_key do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  # Private functions

  defp get_secret_key do
    secret_base = Application.get_env(:tymeslot, TymeslotWeb.Endpoint)[:secret_key_base]

    if is_nil(secret_base) or byte_size(secret_base) < 64 do
      raise "SECRET_KEY_BASE must be at least 64 bytes for secure encryption"
    end

    :crypto.hash(:sha256, secret_base <> @aad)
  end
end
