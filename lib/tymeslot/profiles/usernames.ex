defmodule Tymeslot.Profiles.Usernames do
  @moduledoc """
  Subcomponent for managing profile usernames: generating the system
  default, and the write path every username change takes (see
  `Tymeslot.Profiles.change_username/2` and
  `Tymeslot.Profiles.ensure_default_username/1`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.BookingPage.Publication
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Profiles.ReservedPaths
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.RateLimiter

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

  @doc "See `Tymeslot.Profiles.change_username/2`."
  @spec change(ProfileSchema.t(), username) :: {:ok, ProfileSchema.t()} | {:error, term()}
  def change(%ProfileSchema{} = profile, username), do: write(profile, username, :rate_limited)

  @doc "See `Tymeslot.Profiles.ensure_default_username/1`."
  @spec ensure_default(ProfileSchema.t()) :: {:ok, ProfileSchema.t()} | {:error, term()}
  def ensure_default(%ProfileSchema{username: username} = profile)
      when is_binary(username) and username != "",
      do: {:ok, profile}

  def ensure_default(%ProfileSchema{} = profile),
    do: write(profile, generate_default_username(profile.user_id), :system)

  # Private helpers

  defp write(%ProfileSchema{username: username} = profile, username, _writer),
    do: {:ok, profile}

  defp write(profile, username, writer) do
    with :ok <- UsernameValidator.validate(username),
         :ok <- refuse_reserved(username),
         :ok <- rate_limit(profile, writer),
         {:ok, updated_profile} <- store(profile, username, writer) do
      Publication.maybe_publish(updated_profile.user_id)
      {:ok, updated_profile}
    else
      {:unchanged, stored} ->
        {:ok, stored}

      {:error, :rate_limited, _message} ->
        {:error,
         dgettext(
           "dashboard_profile",
           "Too many username change attempts. Please try again later."
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every reserved username, the demo provider's included, is refused here,
  # before the rate limit, so a refused choice costs no change attempt.
  defp refuse_reserved(username) do
    if ReservedPaths.reserved?(String.trim(username)),
      do: {:error, dgettext("errors", "This username is reserved")},
      else: :ok
  end

  # The system default fills a blank username and nothing else, decided from
  # the stored row: the profile it was given may predate a username chosen
  # since (in another tab, say), which the default must not overwrite.
  defp store(profile, username, :system),
    do: ProfileQueries.update_username_if_blank(profile, username)

  defp store(profile, username, :rate_limited),
    do: ProfileQueries.update_username(profile, username)

  # A system write (the default given when onboarding moves on without a
  # username) is not the user's change, so it costs them no attempt.
  defp rate_limit(_profile, :system), do: :ok

  defp rate_limit(profile, :rate_limited),
    do: RateLimiter.check(:username_change, "user:" <> Integer.to_string(profile.user_id))

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
