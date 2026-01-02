defmodule Tymeslot.Security.CredentialManager do
  @moduledoc """
  Manages secure handling of sensitive credentials in memory.

  This module provides encryption and decryption of credentials to prevent
  plain-text passwords from being passed around in memory. It uses AES-256-GCM
  for encryption with a per-session key stored in the process dictionary.

  ## Security Features
  - In-memory encryption using AES-256-GCM
  - Per-process encryption keys
  - Automatic credential wiping
  - Secure random key generation
  """

  @cipher :aes_256_gcm
  @key_length 32
  @iv_length 16
  @tag_length 16

  @type encrypted_credential :: %{
          ciphertext: binary(),
          iv: binary(),
          tag: binary()
        }

  @doc """
  Encrypts a credential string for secure storage in memory.

  The encryption key is stored in the process dictionary and is unique
  per process to prevent cross-process access.

  ## Examples

      iex> {:ok, encrypted} = CredentialManager.encrypt_credential("my_password")
      iex> is_map(encrypted)
      true
  """
  @spec encrypt_credential(String.t() | nil) ::
          {:ok, encrypted_credential()} | {:ok, nil} | {:error, String.t()}
  def encrypt_credential(nil), do: {:ok, nil}

  def encrypt_credential(credential) when is_binary(credential) do
    key = get_or_create_key()
    iv = :crypto.strong_rand_bytes(@iv_length)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        @cipher,
        key,
        iv,
        credential,
        "",
        @tag_length,
        true
      )

    {:ok,
     %{
       ciphertext: ciphertext,
       iv: iv,
       tag: tag
     }}
  rescue
    e ->
      {:error, "Encryption failed: #{inspect(e)}"}
  end

  @doc """
  Decrypts an encrypted credential back to its original string.

  Uses the process-specific key to decrypt the credential.

  ## Examples

      iex> {:ok, encrypted} = CredentialManager.encrypt_credential("my_password")
      iex> {:ok, decrypted} = CredentialManager.decrypt_credential(encrypted)
      iex> decrypted
      "my_password"
  """
  @spec decrypt_credential(encrypted_credential() | nil) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def decrypt_credential(nil), do: {:ok, nil}

  def decrypt_credential(%{ciphertext: ciphertext, iv: iv, tag: tag}) do
    key = get_or_create_key()

    case :crypto.crypto_one_time_aead(
           @cipher,
           key,
           iv,
           ciphertext,
           "",
           tag,
           false
         ) do
      :error ->
        {:error, "Decryption failed - invalid tag or corrupted data"}

      plaintext ->
        {:ok, plaintext}
    end
  rescue
    e ->
      {:error, "Decryption failed: #{inspect(e)}"}
  end

  @doc """
  Encrypts credentials within a client configuration map.

  Specifically handles username and password fields commonly used
  in calendar integrations.

  ## Examples

      iex> client = %{username: "user", password: "pass", base_url: "https://example.com"}
      iex> {:ok, encrypted_client} = CredentialManager.encrypt_client_credentials(client)
      iex> is_map(encrypted_client.password)
      true
  """
  @spec encrypt_client_credentials(map()) :: {:ok, map()} | {:error, String.t()}
  def encrypt_client_credentials(client) when is_map(client) do
    with {:ok, encrypted_username} <- encrypt_credential(Map.get(client, :username)),
         {:ok, encrypted_password} <- encrypt_credential(Map.get(client, :password)) do
      {:ok,
       client
       |> Map.put(:username_encrypted, encrypted_username)
       |> Map.put(:password_encrypted, encrypted_password)
       |> Map.delete(:username)
       |> Map.delete(:password)}
    end
  end

  @doc """
  Decrypts credentials within a client configuration map.

  Reverses the encryption done by encrypt_client_credentials/1.

  ## Examples

      iex> {:ok, encrypted_client} = CredentialManager.encrypt_client_credentials(client)
      iex> {:ok, decrypted_client} = CredentialManager.decrypt_client_credentials(encrypted_client)
      iex> decrypted_client.username
      "user"
  """
  @spec decrypt_client_credentials(map()) :: {:ok, map()} | {:error, String.t()}
  def decrypt_client_credentials(client) when is_map(client) do
    with {:ok, username} <- decrypt_credential(Map.get(client, :username_encrypted)),
         {:ok, password} <- decrypt_credential(Map.get(client, :password_encrypted)) do
      {:ok,
       client
       |> Map.put(:username, username)
       |> Map.put(:password, password)
       |> Map.delete(:username_encrypted)
       |> Map.delete(:password_encrypted)}
    end
  end

  @doc """
  Executes a function with temporarily decrypted credentials.

  This ensures credentials are only decrypted for the duration of the operation.
  The decrypted values are scoped to the function and will be garbage collected
  after the function completes.

  ## Examples

      iex> {:ok, encrypted} = CredentialManager.encrypt_client_credentials(client)
      iex> CredentialManager.with_decrypted_credentials(encrypted, fn decrypted ->
      ...>   # Use decrypted.username and decrypted.password here
      ...>   {:ok, "result"}
      ...> end)
      {:ok, "result"}
  """
  @spec with_decrypted_credentials(map(), (map() -> any())) :: any()
  def with_decrypted_credentials(encrypted_client, fun) when is_function(fun, 1) do
    case decrypt_client_credentials(encrypted_client) do
      {:ok, decrypted_client} ->
        try do
          fun.(decrypted_client)
        rescue
          error ->
            require Logger
            Logger.error("Error in with_decrypted_credentials", error: inspect(error))
            {:error, :decryption_operation_failed}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Clears the encryption key for the current process.

  Should be called when the process is done handling credentials.
  """
  @spec clear_process_key() :: :ok
  def clear_process_key do
    Process.delete(:credential_encryption_key)
    :ok
  end

  # Private functions

  defp get_or_create_key do
    case Process.get(:credential_encryption_key) do
      nil ->
        key = :crypto.strong_rand_bytes(@key_length)
        Process.put(:credential_encryption_key, key)
        key

      key ->
        key
    end
  end
end
