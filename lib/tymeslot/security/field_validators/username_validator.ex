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
  #
  # The hyphen in the class is escaped because browsers compile `pattern` with
  # the `v` flag, where a bare `-` that is not part of a range is a syntax
  # error; the browser then skips the attribute entirely. PCRE reads `\-` as a
  # literal hyphen, so the server-side regex means exactly the same.
  @username_chars "a-z0-9_\\-"
  @username_pattern "[a-z0-9][#{@username_chars}]*"
  @username_regex ~r/^#{@username_pattern}$/
  @disallowed_char ~r/[^#{@username_chars}]/

  @doc """
  The accepted username shape as an HTML `pattern` attribute value.

  Unanchored, because `pattern` anchors itself, and free of any length bound,
  because `minlength`/`maxlength` carry that half of the rule on the field.
  """
  @spec html_pattern() :: String.t()
  def html_pattern, do: @username_pattern

  @doc "The shortest and longest username accepted by default, as `{min, max}`."
  @spec length_range() :: {pos_integer(), pos_integer()}
  def length_range, do: {@username_min_length, @username_max_length}

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
  def validate(username, opts \\ []) do
    case problem(username, opts) do
      nil -> :ok
      problem -> {:error, message(problem)}
    end
  end

  @typedoc "Why a username is refused, for a caller that words it in its own terms."
  @type problem ::
          :required
          | :not_text
          | {:too_short, pos_integer()}
          | {:too_long, pos_integer()}
          | :format
          | :reserved

  @doc """
  Why `username` is refused, or `nil` when it is accepted: the rules
  `validate/2` applies, as a value rather than a message, so a caller can say
  it in its own words (onboarding calls the username a link). Takes the same
  options as `validate/2`.
  """
  @spec problem(any(), keyword()) :: problem() | nil
  def problem(username, opts \\ [])
  def problem(nil, _opts), do: :required
  def problem("", _opts), do: :required

  def problem(username, opts) when is_binary(username) do
    min_length = Keyword.get(opts, :min_length, @username_min_length)
    max_length = Keyword.get(opts, :max_length, @username_max_length)
    reserved_words = Keyword.get(opts, :reserved_words, nil)

    trimmed_username = String.trim(username)

    length_problem(trimmed_username, min_length, max_length) ||
      format_problem(trimmed_username) ||
      reserved_problem(trimmed_username, reserved_words)
  end

  def problem(_username, _opts), do: :not_text

  @doc """
  Brings typed text towards the accepted username shape: lowercase, accents
  folded to their base letter, each run of whitespace one hyphen, and every
  other character the shape does not allow dropped. Nothing else is changed,
  so the result can still be refused (too short, or starting with a hyphen),
  and `validate/2` says why.

      iex> normalise("Maya O!")
      "maya-o"
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(text) when is_binary(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.trim_leading()
    |> String.replace(~r/\s+/u, "-")
    |> String.replace(@disallowed_char, "")
  end

  # Private helper functions

  defp message(:required), do: dgettext("errors_input", "Username is required")
  defp message(:not_text), do: dgettext("errors_input", "Username must be a text value")
  defp message(:reserved), do: dgettext("errors_input", "This username is reserved")

  defp message({:too_short, min_length}),
    do:
      dngettext(
        "errors_input",
        "Username must be at least %{count} character long",
        "Username must be at least %{count} characters long",
        min_length
      )

  defp message({:too_long, max_length}),
    do:
      dngettext(
        "errors_input",
        "Username must be at most %{count} character long",
        "Username must be at most %{count} characters long",
        max_length
      )

  defp message(:format),
    do:
      dgettext(
        "errors_input",
        "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"
      )

  defp length_problem(username, min_length, max_length) do
    length = String.length(username)

    cond do
      length < min_length -> {:too_short, min_length}
      length > max_length -> {:too_long, max_length}
      true -> nil
    end
  end

  defp format_problem(username),
    do: if(Regex.match?(@username_regex, username), do: nil, else: :format)

  defp reserved_problem(_username, nil), do: nil

  defp reserved_problem(username, reserved_words) when is_list(reserved_words),
    do: if(String.downcase(username) in reserved_words, do: :reserved, else: nil)
end
