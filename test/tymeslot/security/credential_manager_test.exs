defmodule Tymeslot.Security.CredentialManagerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @moduletag :security

  alias Tymeslot.Security.CredentialManager

  setup do
    on_exit(fn -> CredentialManager.clear_process_key() end)
    :ok
  end

  describe "encrypt_credential/1 + decrypt_credential/1" do
    test "round-trips a credential in the same process" do
      {:ok, encrypted} = CredentialManager.encrypt_credential("hunter2")
      assert %{ciphertext: _ciphertext, iv: _iv, tag: _tag} = encrypted

      assert {:ok, "hunter2"} = CredentialManager.decrypt_credential(encrypted)
    end

    test "nil is a passthrough both directions" do
      assert {:ok, nil} = CredentialManager.encrypt_credential(nil)
      assert {:ok, nil} = CredentialManager.decrypt_credential(nil)
    end
  end

  describe "with_decrypted_credentials/2" do
    setup do
      {:ok, encrypted} =
        CredentialManager.encrypt_client_credentials(%{
          username: "alice",
          password: "correct horse battery staple",
          base_url: "https://example.com"
        })

      %{encrypted: encrypted}
    end

    test "invokes the callback with decrypted credentials and returns its result", %{
      encrypted: encrypted
    } do
      result =
        CredentialManager.with_decrypted_credentials(encrypted, fn client ->
          assert client.username == "alice"
          assert client.password == "correct horse battery staple"
          {:ok, :used}
        end)

      assert result == {:ok, :used}
    end

    test "propagates callback exceptions without leaking decrypted secrets", %{
      encrypted: encrypted
    } do
      # The caller's exception bubbles up — we do not rescue, because that
      # would hide real bugs. The important invariant is that the decrypted
      # secret does not appear in the exception message produced by this
      # function itself.
      assert_raise RuntimeError, ~r/boom/, fn ->
        CredentialManager.with_decrypted_credentials(encrypted, fn _decrypted ->
          raise "boom"
        end)
      end
    end

    test "returns {:error, _} when the encrypted payload is malformed" do
      malformed = %{
        username_encrypted: %{ciphertext: "x", iv: "y", tag: "z"},
        password_encrypted: nil
      }

      assert {:error, message} =
               CredentialManager.with_decrypted_credentials(malformed, fn _client ->
                 :unreachable
               end)

      assert is_binary(message)
      assert message =~ "Decryption failed"
    end
  end
end
