defmodule Tymeslot.Security.CredentialReencryptionNotConfiguredTest do
  # async: false — mutates the global DATA_ENCRYPTION_KEY config and the cached
  # keyring in :persistent_term, so it must not run alongside other tests.
  use Tymeslot.DataCase, async: false
  @moduletag :security
  @moduletag :integration

  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.Encryption

  setup do
    original_encryption = Application.get_env(:tymeslot, Encryption)

    on_exit(fn ->
      restore_env(original_encryption)
      Encryption.reset_keyring()
    end)

    :ok
  end

  defp restore_env(nil), do: Application.delete_env(:tymeslot, Encryption)
  defp restore_env(value), do: Application.put_env(:tymeslot, Encryption, value)

  defp put_data_encryption_key(value) do
    Application.put_env(:tymeslot, Encryption, data_encryption_key: value)
    Encryption.reset_keyring()
  end

  describe "run/1 with no DATA_ENCRYPTION_KEY configured" do
    test "returns {:error, :not_configured}" do
      put_data_encryption_key(nil)

      assert Encryption.current_version() == 0
      assert CredentialReencryption.run() == {:error, :not_configured}
    end
  end
end
