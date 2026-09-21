defmodule Tymeslot.Security.FieldValidators.UsernameValidator do
  @moduledoc """
  Username field validation for onboarding.

  Validates username format, length, and character restrictions
  for creating public scheduling URLs.

  Every message returned here is shown to the person choosing their public
  booking URL, in the onboarding wizard and again on the dashboard settings
  page, so each one resolves through the `errors` gettext domain at call time.
  They are built inside the functions rather than held in module attributes
  on purpose: a `dgettext/2` call in an attribute would freeze at the
  compile-time locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @username_min_length 3
  @username_max_length 30
  # One source for the rule, in both the shapes it has to be expressed in: the
  # anchored regex this module validates with, and the unanchored body a form
  # field's `pattern` attribute takes. They were written out separately once
  # and drifted — the browser copy omitted the underscore, which every default
  # username has (`Profiles.Usernames.generate_default_username/1` builds
  # "user_<id>"), so the profile form refused to submit for any account that
  # had never customised its URL.
  @username_pattern "[a-z0-9][a-z0-9_-]*"
  @username_regex ~r/^#{@username_pattern}$/

  @doc """
  The accepted username shape as an HTML `pattern` attribute value.

  Unanchored, because `pattern` anchors itself, and free of any length bound,
  because `minlength`/`maxlength` carry that half of the rule on the field.
  """
  @spec html_pattern() :: String.t()
  def html_pattern, do: @username_pattern

  @doc """
  Validates username with specific error messages.

  ## Examples

      iex> validate("john_smith")
      :ok

      iex> validate("ab")
      {:error, "Username must be at least 3 characters long"}

      iex> validate("john@smith")
      {:error, "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"}

  The messages above are the English ones; each is translated into the
  caller's locale.
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(username, opts \\ [])

  def validate(nil, _opts), do: {:error, dgettext("errors", "Username is required")}
  def validate("", _opts), do: {:error, dgettext("errors", "Username is required")}

  def validate(username, opts) when is_binary(username) do
    min_length = Keyword.get(opts, :min_length, @username_min_length)
    max_length = Keyword.get(opts, :max_length, @username_max_length)
    reserved_words = Keyword.get(opts, :reserved_words, nil)

    trimmed_username = String.trim(username)

    with :ok <- validate_length(trimmed_username, min_length, max_length),
         :ok <- validate_format(trimmed_username) do
      validate_reserved_words(trimmed_username, reserved_words)
    end
  end

  def validate(_username, _opts) do
    {:error, dgettext("errors", "Username must be a text value")}
  end

  # Private helper functions

  defp validate_length(username, min_length, max_length) do
    length = String.length(username)

    cond do
      length < min_length ->
        {:error,
         dngettext(
           "errors",
           "Username must be at least %{count} character long",
           "Username must be at least %{count} characters long",
           min_length
         )}

      length > max_length ->
        {:error,
         dngettext(
           "errors",
           "Username must be at most %{count} character long",
           "Username must be at most %{count} characters long",
           max_length
         )}

      true ->
        :ok
    end
  end

  defp validate_format(username) do
    if Regex.match?(@username_regex, username) do
      :ok
    else
      {:error,
       dgettext(
         "errors",
         "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"
       )}
    end
  end

  defp validate_reserved_words(_username, nil), do: :ok

  defp validate_reserved_words(username, reserved_words) when is_list(reserved_words) do
    lowercase_username = String.downcase(username)

    if lowercase_username in reserved_words do
      {:error, dgettext("errors", "This username is reserved")}
    else
      :ok
    end
  end
end
