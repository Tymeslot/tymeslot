defmodule Tymeslot.Test.LegacyCiphertext do
  @moduledoc """
  Builds ciphertext in the legacy (v0), prefix-less format that
  `Tymeslot.Security.Encryption` still reads but no longer writes.

  The key derivation mirrors the legacy key in `Encryption`: SHA-256 of
  `secret_key_base` concatenated with the AAD string. Tests use it to seed
  rows that the re-encryption sweep must upgrade.
  """

  @aad "Tymeslot.Encryption"
  @nonce_size 12

  @doc "Encrypts `plaintext` under the legacy key, in the legacy format."
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    secret_base = Application.fetch_env!(:tymeslot, TymeslotWeb.Endpoint)[:secret_key_base]
    legacy_key = :crypto.hash(:sha256, secret_base <> @aad)
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, legacy_key, nonce, plaintext, @aad, true)

    nonce <> tag <> ciphertext
  end
end
