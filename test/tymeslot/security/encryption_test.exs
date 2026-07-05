defmodule Tymeslot.Security.EncryptionTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.Encryption

  describe "encrypt/1 and decrypt/1" do
    test "encrypts and decrypts a string successfully" do
      plaintext = "sensitive_password"

      encrypted = Encryption.encrypt(plaintext)
      assert is_binary(encrypted)
      assert encrypted != plaintext

      decrypted = Encryption.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "handles nil values for encrypt" do
      assert Encryption.encrypt(nil) == nil
    end

    test "handles nil values for decrypt" do
      assert Encryption.decrypt(nil) == nil
    end

    test "encrypts different values to different ciphertexts" do
      plaintext1 = "password123"
      plaintext2 = "password123"

      encrypted1 = Encryption.encrypt(plaintext1)
      encrypted2 = Encryption.encrypt(plaintext2)

      # Same plaintext should produce different ciphertexts due to random nonce
      assert encrypted1 != encrypted2

      # But both should decrypt to the same value
      assert Encryption.decrypt(encrypted1) == plaintext1
      assert Encryption.decrypt(encrypted2) == plaintext2
    end

    test "encrypted value is longer than plaintext due to nonce and tag" do
      plaintext = "test"

      encrypted = Encryption.encrypt(plaintext)

      # Encrypted should include: 12-byte nonce + 16-byte tag + ciphertext
      assert byte_size(encrypted) > byte_size(plaintext)
      assert byte_size(encrypted) >= 28 + byte_size(plaintext)
    end

    test "decrypts to correct value regardless of plaintext length" do
      short_text = "ab"
      medium_text = "this is a medium length password"
      long_text = String.duplicate("a", 1000)

      assert short_text == Encryption.decrypt(Encryption.encrypt(short_text))
      assert medium_text == Encryption.decrypt(Encryption.encrypt(medium_text))
      assert long_text == Encryption.decrypt(Encryption.encrypt(long_text))
    end

    test "handles Unicode characters correctly" do
      plaintext = "пароль密码🔐"

      encrypted = Encryption.encrypt(plaintext)
      decrypted = Encryption.decrypt(encrypted)

      assert decrypted == plaintext
    end

    test "returns nil for corrupted ciphertext" do
      plaintext = "password"
      encrypted = Encryption.encrypt(plaintext)

      # Corrupt the ciphertext by flipping a bit
      <<first::binary-size(10), _remainder::binary>> = encrypted
      corrupted = first <> "corrupted"

      assert Encryption.decrypt(corrupted) == nil
    end

    test "returns nil for ciphertext that is too short" do
      short_binary = "short"

      assert Encryption.decrypt(short_binary) == nil
    end

    test "round-trips an empty string without losing it" do
      encrypted = Encryption.encrypt("")
      assert Encryption.decrypt(encrypted) == ""
    end

    test "handles long strings encryption" do
      plaintext = String.duplicate("Long password with many characters ", 100)

      encrypted = Encryption.encrypt(plaintext)
      decrypted = Encryption.decrypt(encrypted)

      assert decrypted == plaintext
    end
  end

  describe "generate_api_key/0" do
    test "generates a random API key" do
      key = Encryption.generate_api_key()

      assert is_binary(key)
      assert String.length(key) > 0
    end

    test "generates unique keys on each call" do
      key1 = Encryption.generate_api_key()
      key2 = Encryption.generate_api_key()

      assert key1 != key2
    end

    test "generates URL-safe base64 keys" do
      key = Encryption.generate_api_key()

      # Should not contain padding characters
      refute String.contains?(key, "=")

      # Should be URL-safe (no +, /)
      refute String.contains?(key, "+")
      refute String.contains?(key, "/")
    end

    test "generates keys of consistent format" do
      keys = for _i <- 1..10, do: Encryption.generate_api_key()

      Enum.each(keys, fn key ->
        assert is_binary(key)
        assert String.length(key) > 40
      end)
    end
  end

  describe "encryption security properties" do
    test "uses AES-256-GCM authenticated encryption" do
      plaintext = "test_password"

      encrypted = Encryption.encrypt(plaintext)

      # Should have 12-byte nonce + 16-byte tag
      assert byte_size(encrypted) >= 28
    end

    test "different nonces for each encryption" do
      plaintext = "same_password"

      encrypted1 = Encryption.encrypt(plaintext)
      encrypted2 = Encryption.encrypt(plaintext)

      # Extract nonces (first 12 bytes)
      <<nonce1::binary-12, _rest1::binary>> = encrypted1
      <<nonce2::binary-12, _rest2::binary>> = encrypted2

      # Nonces should be different
      assert nonce1 != nonce2
    end

    test "tampering detection through authentication tag" do
      plaintext = "password"
      encrypted = Encryption.encrypt(plaintext)

      # Tamper with the tag portion (bytes 12-28)
      <<nonce::binary-12, _auth_tag::binary-16, ciphertext::binary>> = encrypted
      tampered = nonce <> :crypto.strong_rand_bytes(16) <> ciphertext

      # decrypt/1 raises on tampering so noisy failure modes stay loud.
      assert_raise RuntimeError, fn ->
        Encryption.decrypt(tampered)
      end

      # decrypt_with_status/1 surfaces the same failure as a tagged tuple so
      # calendar sync workers can flag the integration for reauth instead.
      assert Encryption.decrypt_with_status(tampered) == {:error, :requires_reencryption}
    end
  end

  describe "versioned keyring" do
    test "stamps the current version byte on new writes" do
      <<version, _rest::binary>> = Encryption.encrypt("token")

      assert version == Encryption.current_version()
      assert Encryption.current_version() == 1
    end

    test "current?/1 is true for fresh writes and false for legacy values" do
      assert Encryption.current?(Encryption.encrypt("token"))
      refute Encryption.current?(Encryption.encrypt_legacy("token"))
      refute Encryption.current?("not ciphertext")
    end

    test "decrypts a legacy v0 value and re-encrypts it to the current version" do
      legacy = Encryption.encrypt_legacy("secret-token")

      # Legacy values carry no version prefix and open under the fallback key.
      assert Encryption.decrypt(legacy) == "secret-token"
      assert Encryption.decrypt_with_status(legacy) == {:ok, "secret-token"}
      refute Encryption.current?(legacy)

      reencrypted = Encryption.encrypt(Encryption.decrypt(legacy))

      assert Encryption.current?(reencrypted)
      assert Encryption.decrypt(reencrypted) == "secret-token"
    end

    test "detects tampering of a current-version value" do
      <<version, nonce::binary-12, _tag::binary-16, ciphertext::binary>> =
        Encryption.encrypt("password")

      tampered =
        <<version, nonce::binary, :crypto.strong_rand_bytes(16)::binary, ciphertext::binary>>

      assert Encryption.decrypt_with_status(tampered) == {:error, :requires_reencryption}
      assert_raise RuntimeError, fn -> Encryption.decrypt(tampered) end
    end

    test "a legacy value whose leading byte collides with the current version still decrypts" do
      current = Encryption.current_version()

      # Legacy blobs begin with a random nonce byte, so ~1/256 start with the
      # current version id. Trial decryption must still route those to the legacy
      # key rather than mistaking them for current-version ciphertext.
      collision =
        Stream.repeatedly(fn -> Encryption.encrypt_legacy("collide") end)
        |> Stream.take(50_000)
        |> Enum.find(fn <<byte, _rest::binary>> -> byte == current end)

      assert is_binary(collision), "expected at least one leading-byte collision in the sample"
      assert Encryption.decrypt(collision) == "collide"
      refute Encryption.current?(collision)
    end
  end
end
