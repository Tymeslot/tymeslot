defmodule Tymeslot.Security.Password do
  @moduledoc """
  Password hashing and verification helpers, using Bcrypt.
  """

  @spec hash_password(String.t()) :: String.t()
  def hash_password(password) when is_binary(password) do
    Bcrypt.hash_pwd_salt(password)
  end

  @spec verify_password(String.t(), String.t()) :: boolean()
  def verify_password(password, hashed_password)
      when is_binary(password) and is_binary(hashed_password) do
    Bcrypt.verify_pass(password, hashed_password)
  end
end
