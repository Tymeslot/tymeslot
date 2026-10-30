defmodule Tymeslot.Profiles.Usernames do
  @moduledoc """
  Subcomponent for managing profile usernames: generating the system
  default, whether a username can be taken and why a write refused one, and
  the write path every username change takes (see
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

  @doc """
  Whether `username` can become `profile`'s username, and if not, why.

  Surrounding whitespace is ignored. The profile's own current username is
  `:unchanged` and is never re-checked, so a handle chosen before its word was
  reserved keeps working. Otherwise the format is checked first, then the
  reserved list, then whether another profile already holds it. `profile` may
  be `nil` when there is no profile yet.

  The profile changeset enforces the same rules again on write, which is what
  settles a username taken between this check and the save.
  """
  @spec status(ProfileSchema.t() | map() | nil, term()) ::
          :unchanged | :ok | {:invalid, String.t()} | :reserved | :taken
  def status(profile, username) when is_binary(username) do
    candidate = String.trim(username)

    if current_username?(profile, candidate),
      do: :unchanged,
      else: new_username_status(candidate)
  end

  def status(_profile, username), do: new_username_status(username)

  defp current_username?(%{username: current}, candidate) when is_binary(current),
    do: current == candidate

  defp current_username?(_profile, _candidate), do: false

  defp new_username_status(username) do
    with :ok <- username_format_status(username),
         :ok <- username_reserved_status(username) do
      if ProfileQueries.username_available?(username), do: :ok, else: :taken
    end
  end

  defp username_format_status(username) do
    case UsernameValidator.validate(username) do
      :ok -> :ok
      {:error, message} -> {:invalid, message}
    end
  end

  defp username_reserved_status(username) do
    if ReservedPaths.reserved?(username), do: :reserved, else: :ok
  end

  @doc """
  Why a profile changeset refused its username: `:taken` when another profile
  holds it, `:reserved` when it is on the reserved list, `nil` for anything
  else (a malformed username, or an error on another field).
  """
  @spec error(Ecto.Changeset.t()) :: :reserved | :taken | nil
  def error(%Ecto.Changeset{errors: errors}) do
    errors
    |> Keyword.get_values(:username)
    |> Enum.find_value(&username_error_kind/1)
  end

  defp username_error_kind({_message, opts}) do
    cond do
      opts[:constraint] == :unique -> :taken
      opts[:validation] == :reserved -> :reserved
      true -> nil
    end
  end
end
