defmodule Tymeslot.Profiles.Usernames do
  @moduledoc """
  Subcomponent for managing profile usernames.
  Focuses on generation and validation logic.
  """

  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Profiles.ReservedPaths

  @type username :: String.t()
  @type user_id :: pos_integer()

  @doc """
  Generates a unique default username for a user.
  """
  @spec generate_default_username(user_id) :: username
  def generate_default_username(user_id) do
    base = "user_#{user_id}"

    if ProfileQueries.username_available?(base) do
      base
    else
      generate_random_username(base, 3)
    end
  end

  @doc """
  Validates username format and reserved paths.
  """
  @spec validate_username_format(term()) :: :ok | {:error, String.t()}
  def validate_username_format(username) when is_binary(username) do
    cond do
      String.length(username) < 3 ->
        {:error, "Username must be at least 3 characters long"}

      String.length(username) > 30 ->
        {:error, "Username must be at most 30 characters long"}

      !Regex.match?(~r/^[a-z0-9][a-z0-9_-]{2,29}$/, username) ->
        {:error,
         "Username must contain only lowercase letters, numbers, underscores, and hyphens, and start with a letter or number"}

      username in ReservedPaths.list() ->
        {:error, "This username is reserved"}

      true ->
        :ok
    end
  end

  def validate_username_format(_input), do: {:error, "Username must be a string"}

  # Private helpers

  defp generate_random_username(base, 0), do: "#{base}_#{random_suffix()}"

  defp generate_random_username(base, attempts) do
    candidate = "#{base}_#{random_suffix()}"

    if ProfileQueries.username_available?(candidate) do
      candidate
    else
      generate_random_username(base, attempts - 1)
    end
  end

  defp random_suffix do
    Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end
end
