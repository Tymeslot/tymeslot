defmodule Tymeslot.Profiles.Usernames do
  @moduledoc """
  Subcomponent for managing profile usernames.
  Focuses on generation and validation logic.
  """

  alias Tymeslot.Profiles.ProfileQueries

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
