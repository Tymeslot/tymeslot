defmodule Tymeslot.Security.Encryption do
  @moduledoc """
  Handles encryption and decryption of sensitive data in the database.
  Uses AES-256-GCM for authenticated encryption.
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

    # Combine nonce, tag, and ciphertext into a single binary
    nonce <> tag <> ciphertext
  end

  @doc """
  Decrypts a value that was encrypted with encrypt/1.
  Returns the original plaintext string.
  """
  @spec decrypt(nil) :: nil
  def decrypt(nil), do: nil

  @spec decrypt(binary()) :: binary() | nil
  def decrypt(encrypted) when is_binary(encrypted) and byte_size(encrypted) > 28 do
    secret_key = get_secret_key()

    # Extract components
    <<nonce::binary-12, tag::binary-16, ciphertext::binary>> = encrypted

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           secret_key,
           nonce,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      :error ->
        raise "Failed to decrypt data. The data may be corrupted or the key may have changed."

      plaintext ->
        plaintext
    end
  end

  def decrypt(_), do: nil

  @doc """
  Generates a new random API key.
  """
  @spec generate_api_key() :: String.t()
  def generate_api_key do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  # Private functions

  defp get_secret_key do
    # Use the SECRET_KEY_BASE for encryption, but derive a specific key for this purpose
    secret_base =
      Application.get_env(:tymeslot, TymeslotWeb.Endpoint)[:secret_key_base]

    if is_nil(secret_base) or byte_size(secret_base) < 64 do
      raise "SECRET_KEY_BASE must be at least 64 bytes for secure encryption"
    end

    # Derive a 32-byte key for AES-256
    :crypto.hash(:sha256, secret_base <> @aad)
  end
end
