defmodule Tymeslot.Emails.EmailScheduler.LinkArg do
  @moduledoc """
  Carries a link holding a live account token (password reset, email
  verification, email change) through an Oban job without persisting it in
  the clear.

  Job args sit in `oban_jobs` long after the email is sent, and anyone who can
  read that table must not be able to lift a working reset link from it. The
  link is therefore stored encrypted under `Tymeslot.Security.Encryption`,
  Base64-encoded to survive JSON, under `"<key>_encrypted"`.

  `fetch/2` still accepts the old plaintext `"<key>"` arg, so jobs enqueued
  before this shape existed are delivered rather than lost mid-deploy.
  """

  alias Tymeslot.Security.Encryption

  @doc """
  Puts `url` into `args` encrypted, under `"<key>_encrypted"`.
  """
  @spec put(map(), String.t(), String.t()) :: map()
  def put(args, key, url) when is_binary(key) and is_binary(url) do
    Map.put(args, encrypted_key(key), url |> Encryption.encrypt() |> Base.encode64())
  end

  @doc """
  The name of the job arg `put/3` writes for `key`.
  """
  @spec encrypted_key(String.t()) :: String.t()
  def encrypted_key(key), do: key <> "_encrypted"

  @doc """
  Reads the link stored under `key`: the encrypted arg when present, otherwise
  a legacy plaintext one. Returns `:error` when neither is present or the
  ciphertext cannot be opened (tampered, or its key rotated away).
  """
  @spec fetch(map(), String.t()) :: {:ok, String.t()} | :error
  def fetch(args, key) do
    case Map.fetch(args, encrypted_key(key)) do
      {:ok, encoded} -> decrypt(encoded)
      :error -> legacy(Map.get(args, key))
    end
  end

  defp decrypt(encoded) when is_binary(encoded) do
    with {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, url} when is_binary(url) <- Encryption.decrypt_with_status(ciphertext) do
      {:ok, url}
    else
      _unreadable -> :error
    end
  end

  defp decrypt(_malformed), do: :error

  defp legacy(url) when is_binary(url), do: {:ok, url}
  defp legacy(_missing), do: :error
end
