defmodule Tymeslot.Security.FieldValidators.EmailValidator do
  @moduledoc """
  Email field validation with precise error messages.

  Validates email format without domain existence checking,
  providing specific feedback for common email format issues.

  The local part must be an RFC 5322 dot-atom and the domain a run of
  hostname labels. Both halves also accept any non-ASCII character other
  than whitespace and control, format or other invisible characters, so
  internationalised addresses (RFC 6531) pass; this is broader than letters,
  admitting non-ASCII punctuation and symbols too.

  The format rules apply to an address being entered: at sign-up, on an
  email change, on a booking or invitation form. An address that is already
  an account's stored identity may predate the current rules and not meet
  them, so a sign-in or reset lookup, or a copy of the stored address, passes
  `existing: true` to check only presence and length.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.FieldValidators.TLDList

  @email_max_length 254
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  # Any character outside ASCII that is neither whitespace (`\p{Z}`) nor a
  # control, format, private-use, surrogate or unassigned code point (`\p{C}`).
  # This admits non-ASCII letters, as RFC 6531 needs for an internationalised
  # address (`jürgen@müller.de`), and also non-ASCII punctuation and symbols.
  @non_ascii "(?![\\p{Z}\\p{C}])[^\\x00-\\x7F]"

  # The local part as an RFC 5322 dot-atom: runs of `atext` joined by single
  # dots. Quoted local parts and the specials `( ) < > [ ] : ; , \ "` are
  # refused: no real mailbox needs them, and each is a character a mail
  # header, a log line or a display name gives a meaning of its own.
  @atext "[A-Za-z0-9!#$%&'*+\\-/=?^_`{|}~]|#{@non_ascii}"
  @local_part_regex ~r/\A(?:#{@atext})+(?:\.(?:#{@atext})+)*\z/u

  # The domain as hostname labels: letters, digits and hyphens (or an
  # internationalised label), so no address literal and no specials.
  @label_char "[A-Za-z0-9-]|#{@non_ascii}"
  @domain_regex ~r/\A(?:#{@label_char})+(?:\.(?:#{@label_char})+)+\z/u

  @doc """
  Validates email format with specific error messages.

  ## Examples

      iex> validate("user@example.com")
      :ok
      
      iex> validate("userexample.com")
      {:error, "Email format is invalid (missing @ symbol)"}
      
      iex> validate("user@")
      {:error, "Email domain is missing"}

      iex> validate(~s("quoted"@example.com), existing: true)
      :ok

  ## Options

    * `:max_length` - the longest address accepted (default #{@email_max_length})
    * `:existing` - `true` for an address that is already a stored identity:
      only presence and length are checked, never the format
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(email, opts \\ [])

  def validate(nil, _opts), do: {:error, dgettext("errors_input", "Email is required")}
  def validate("", _opts), do: {:error, dgettext("errors_input", "Email is required")}

  def validate(email, opts) when is_binary(email) do
    max_length = Keyword.get(opts, :max_length, @email_max_length)

    with :ok <- validate_length(email, max_length) do
      if Keyword.get(opts, :existing, false), do: :ok, else: validate_format(email)
    end
  end

  def validate(_email, _opts) do
    {:error, dgettext("errors_input", "Email must be a text value")}
  end

  # Private helper functions

  defp validate_format(email) do
    with :ok <- validate_basic_format(email),
         :ok <- validate_advanced_format(email) do
      validate_tld(email)
    end
  end

  defp validate_length(email, max_length) do
    if String.length(email) > max_length do
      {:error,
       dgettext("errors_input", "Email exceeds maximum length (%{max_length} characters)",
         max_length: max_length
       )}
    else
      :ok
    end
  end

  defp validate_basic_format(email) do
    cond do
      not String.contains?(email, "@") ->
        {:error, dgettext("errors_input", "Email format is invalid (missing @ symbol)")}

      String.ends_with?(email, "@") ->
        {:error, dgettext("errors_input", "Email domain is missing")}

      String.starts_with?(email, "@") ->
        {:error, dgettext("errors_input", "Email username is missing")}

      String.contains?(email, "..") ->
        {:error,
         dgettext("errors_input", "Email format is invalid (consecutive dots not allowed)")}

      String.contains?(email, " ") ->
        {:error, dgettext("errors_input", "Email format is invalid (spaces not allowed)")}

      true ->
        :ok
    end
  end

  defp validate_advanced_format(email) do
    cond do
      multiple_at_symbols?(email) ->
        {:error, dgettext("errors_input", "Email format is invalid (multiple @ symbols)")}

      invalid_domain_format?(email) ->
        {:error, dgettext("errors_input", "Email domain format is invalid")}

      not Regex.match?(@email_regex, email) ->
        {:error, dgettext("errors_input", "Email format is invalid")}

      not Regex.match?(@local_part_regex, local_part(email)) ->
        {:error, dgettext("errors_input", "Email format is invalid")}

      not Regex.match?(@domain_regex, domain(email)) ->
        {:error, dgettext("errors_input", "Email domain format is invalid")}

      true ->
        :ok
    end
  end

  defp local_part(email), do: email |> String.split("@", parts: 2) |> hd()
  defp domain(email), do: email |> String.split("@", parts: 2) |> List.last()

  defp multiple_at_symbols?(email) do
    email
    |> String.graphemes()
    |> Enum.count(&(&1 == "@")) > 1
  end

  defp validate_tld(email) do
    [_username, domain] = String.split(email, "@", parts: 2)
    tld = TLDList.extract_tld(domain)
    TLDList.validate_tld(tld, "Email")
  end

  defp invalid_domain_format?(email) do
    [_username, domain] = String.split(email, "@", parts: 2)

    cond do
      String.starts_with?(domain, ".") -> true
      String.ends_with?(domain, ".") -> true
      not String.contains?(domain, ".") -> true
      String.length(domain) < 3 -> true
      true -> false
    end
  end
end
