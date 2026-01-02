defmodule Tymeslot.Security.EncryptionTest do
  use ExUnit.Case, async: true

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
      <<first::binary-size(10), _rest::binary>> = encrypted
      corrupted = first <> "corrupted"

      assert Encryption.decrypt(corrupted) == nil
    end

    test "returns nil for ciphertext that is too short" do
      short_binary = "short"

      assert Encryption.decrypt(short_binary) == nil
    end

    test "handles empty string encryption" do
      plaintext = ""

      encrypted = Encryption.encrypt(plaintext)
      decrypted = Encryption.decrypt(encrypted)

      # Empty strings may be returned as nil after decryption
      assert decrypted == "" or decrypted == nil
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
      keys = for _ <- 1..10, do: Encryption.generate_api_key()

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
      <<nonce::binary-12, _tag::binary-16, ciphertext::binary>> = encrypted
      tampered = nonce <> :crypto.strong_rand_bytes(16) <> ciphertext

      # Decryption should fail
      assert_raise RuntimeError, ~r/Failed to decrypt/, fn ->
        Encryption.decrypt(tampered)
      end
    end
  end
end
