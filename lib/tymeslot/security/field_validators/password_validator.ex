defmodule Tymeslot.Security.FieldValidators.PasswordValidator do
  @moduledoc """
  Password field validation with security requirements.

  Validates password complexity, length, and security patterns
  while providing specific feedback for security requirements.

  The rules live here as data (`rules/0`) rather than as a hand-written
  `cond`, because they have two audiences: this module enforces them, and the
  on-screen checklist has to state them. Those drifted apart once already, and
  the special-character rule was enforced while going unmentioned, so a
  password satisfying every rule the user could see was still rejected.

  Every message returned here reaches the person typing the password — the
  reset form, the signup form, the account security page — so each one resolves
  through the `auth` gettext domain at call time. The complexity messages are
  stored as msgids (`dgettext_noop/2`) because a `dgettext/2` call in a module
  attribute would freeze them at the compile-time locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @password_min_length 8
  @password_max_length 80

  # Ordered as they are enforced, so the message names the first rule broken
  # and the checklist lists them in the same order it checks them. Each rule
  # carries the pattern's source, not just the compiled regex, because the
  # browser-side checklist tests against the very same source — which is what
  # keeps what we enforce and what we tell the user from drifting apart.
  @complexity_rules [
    {:lowercase, ~S([a-z]),
     dgettext_noop("auth", "Password must contain at least one lowercase letter")},
    {:uppercase, ~S([A-Z]),
     dgettext_noop("auth", "Password must contain at least one uppercase letter")},
    {:number, ~S([0-9]), dgettext_noop("auth", "Password must contain at least one number")},
    {:special, ~S([^A-Za-z0-9]),
     dgettext_noop("auth", "Password must contain at least one special character")}
  ]

  @compiled_complexity_rules Enum.map(@complexity_rules, fn {key, pattern, message} ->
                               {key, Regex.compile!(pattern), message}
                             end)

  @rules [
    %{key: :length, pattern: "^.{#{@password_min_length},}$"}
    | Enum.map(@complexity_rules, fn {key, pattern, _message} ->
        %{key: key, pattern: pattern}
      end)
  ]

  @doc """
  Validates password with security requirements and specific error messages.

  ## Examples

      iex> validate("StrongPass123")
      :ok

      iex> validate("weak")
      {:error, "Password must be at least 8 characters long"}

      iex> validate("nouppercase123")
      {:error, "Password must contain at least one uppercase letter"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(password, opts \\ [])

  def validate(nil, _opts), do: {:error, dgettext("auth", "Password is required")}
  def validate("", _opts), do: {:error, dgettext("auth", "Password is required")}

  def validate(password, opts) when is_binary(password) do
    min_length = Keyword.get(opts, :min_length, @password_min_length)
    max_length = Keyword.get(opts, :max_length, @password_max_length)

    with :ok <- validate_length(password, min_length, max_length) do
      validate_complexity(password)
    end
  end

  def validate(_password, _opts) do
    {:error, dgettext("auth", "Password must be a text value")}
  end

  @doc """
  The rules a password must satisfy, in the order they are enforced.

  Each rule carries a regular-expression source rather than a compiled
  `Regex`, so the same pattern can be handed to the browser for the live
  checklist. The syntax used is common to Elixir and JavaScript.
  """
  @spec rules() :: [%{key: atom(), pattern: String.t()}]
  def rules, do: @rules

  @doc """
  The minimum password length, for callers that need to state it.
  """
  @spec min_length() :: pos_integer()
  def min_length, do: @password_min_length

  @doc """
  Validates password confirmation matches original password.
  """
  @spec validate_confirmation(any(), any(), keyword()) :: :ok | {:error, String.t()}
  def validate_confirmation(password, confirmation, opts \\ [])

  def validate_confirmation(password, password, _opts) when is_binary(password) do
    :ok
  end

  def validate_confirmation(_password, nil, _opts) do
    {:error, dgettext("auth", "Password confirmation is required")}
  end

  def validate_confirmation(_password, "", _opts) do
    {:error, dgettext("auth", "Password confirmation is required")}
  end

  def validate_confirmation(_password, _confirmation, _opts) do
    {:error, dgettext("auth", "Password confirmation does not match")}
  end

  # Private helper functions

  defp validate_length(password, min_length, max_length) do
    length = String.length(password)

    cond do
      length < min_length ->
        {:error,
         dngettext(
           "auth",
           "Password must be at least %{count} character long",
           "Password must be at least %{count} characters long",
           min_length
         )}

      length > max_length ->
        {:error,
         dngettext(
           "auth",
           "Password must be at most %{count} character long",
           "Password must be at most %{count} characters long",
           max_length
         )}

      true ->
        :ok
    end
  end

  defp validate_complexity(password) do
    case Enum.find(@compiled_complexity_rules, fn {_key, regex, _message} ->
           not String.match?(password, regex)
         end) do
      nil -> :ok
      {_key, _regex, message} -> {:error, Gettext.dgettext(TymeslotWeb.Gettext, "auth", message)}
    end
  end
end
