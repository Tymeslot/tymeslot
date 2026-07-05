defmodule Tymeslot.Security.EncryptionKeyringConfigTest do
  # async: false — these tests mutate the global DATA_ENCRYPTION_KEY config and the
  # cached keyring in :persistent_term, so they must not run alongside other tests.
  use ExUnit.Case, async: false
  @moduletag :security

  alias Tymeslot.Security.Encryption

  @endpoint TymeslotWeb.Endpoint

  setup do
    original_encryption = Application.get_env(:tymeslot, Encryption)
    original_endpoint = Application.get_env(:tymeslot, @endpoint)

    on_exit(fn ->
      restore_env(Encryption, original_encryption)
      restore_env(@endpoint, original_endpoint)
      Encryption.reset_keyring()
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)

  defp put_secret_key_base(key) do
    base = Application.get_env(:tymeslot, @endpoint) || []
    Application.put_env(:tymeslot, @endpoint, Keyword.put(base, :secret_key_base, key))
    Encryption.reset_keyring()
  end

  defp put_data_encryption_key(value) do
    Application.put_env(:tymeslot, Encryption, data_encryption_key: value)
    Encryption.reset_keyring()
  end

  test "falls back to the legacy format when DATA_ENCRYPTION_KEY is absent" do
    put_data_encryption_key(nil)

    assert Encryption.current_version() == 0

    encrypted = Encryption.encrypt("legacy-write")
    # No version prefix — a bare nonce <> tag <> ciphertext envelope.
    <<_nonce::binary-12, _tag::binary-16, _ciphertext::binary>> = encrypted
    assert Encryption.decrypt(encrypted) == "legacy-write"

    # The value stays readable once the dedicated key is configured, proving it
    # was written in the still-supported legacy format.
    put_data_encryption_key("RsxoYoIVSu/K+QDV2yukDwTFD3wDyDSFxuGmoauNAX0FcXJF58dAz5LhEyiNqhFP")

    assert Encryption.current_version() == 1
    assert Encryption.decrypt(encrypted) == "legacy-write"
    refute Encryption.current?(encrypted)
  end

  test "rotating SECRET_KEY_BASE does not break decryption of current-version values" do
    encrypted = Encryption.encrypt("still-readable")

    # Rotate the session-signing secret — the whole point of the decoupling is
    # that this no longer touches data-at-rest, which is keyed on DATA_ENCRYPTION_KEY.
    put_secret_key_base(String.duplicate("z", 64))

    assert Encryption.decrypt(encrypted) == "still-readable"
  end

  test "raises when DATA_ENCRYPTION_KEY is not valid Base64" do
    put_data_encryption_key("not valid base64 !!!")

    assert_raise RuntimeError, ~r/valid Base64/, fn -> Encryption.encrypt("x") end
  end

  test "raises when DATA_ENCRYPTION_KEY decodes to fewer than 32 bytes" do
    short_key = Base.encode64(:crypto.strong_rand_bytes(16))
    put_data_encryption_key(short_key)

    assert_raise RuntimeError, ~r/at least 32 bytes/, fn -> Encryption.encrypt("x") end
  end
end
