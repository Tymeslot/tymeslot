defmodule Tymeslot.Validation.AddressList do
  @moduledoc """
  Reads the addresses a host types in whom to invite: one or several,
  separated by commas, semicolons or line breaks, each a bare address or
  `Name <address>`, where a double-quoted name (an RFC 5322 display name,
  `"Hopper, Grace" <grace@example.com>`) may hold separators too.

  Shared by every field a host invites people from, so a name typed (or
  filled in from a contact suggestion) is read the same way in each: poll
  invitations (`Tymeslot.Polls.Invitations`), Quick Add's guests and a
  booking's "Add guests".
  """

  alias Tymeslot.Security.FieldValidators.{EmailValidator, NameValidator}

  @type entry :: %{email: String.t(), name: String.t() | nil}

  # One entry is a run of anything but a separator, where a double-quoted
  # stretch may hold separators too. A quote never spans lines, so an
  # unclosed one cannot swallow the entries after it.
  @entry ~r/(?:"[^"\n\r]*"|[^\n\r,;])+/
  @named ~r/^(.*?)\s*<\s*([^<>\s]+)\s*>$/

  @doc "The entries in `text`, trimmed, blanks left out, as typed."
  @spec split(String.t() | nil) :: [String.t()]
  def split(text) when is_binary(text) do
    @entry
    |> Regex.scan(text)
    |> Enum.map(fn [entry] -> String.trim(entry) end)
    |> Enum.reject(&(&1 == ""))
  end

  def split(_text), do: []

  @doc """
  One entry read into its address, trimmed and downcased, and its name,
  `nil` without one. Nothing is validated here (see `valid_address?/1` and
  `valid_name?/1`).
  """
  @spec parse_entry(String.t()) :: entry()
  def parse_entry(raw) when is_binary(raw) do
    case Regex.run(@named, String.trim(raw)) do
      [_raw, name, email] -> %{email: normalise(email), name: blank_to_nil(name)}
      nil -> %{email: normalise(raw), name: nil}
    end
  end

  @doc "Whether the entry's address is one anyone can be invited at."
  @spec valid_address?(entry()) :: boolean()
  def valid_address?(%{email: email}), do: EmailValidator.validate(email) == :ok

  @doc "Whether the entry's name, if it has one, is one a guest or participant can be given."
  @spec valid_name?(entry()) :: boolean()
  def valid_name?(%{name: nil}), do: true
  def valid_name?(%{name: name}), do: NameValidator.validate(name) == :ok

  @doc "The entry as `Name <address>`, or the bare address without a name."
  @spec format(entry()) :: String.t()
  def format(%{email: email, name: nil}), do: email
  def format(%{email: email, name: name}), do: "#{name} <#{email}>"

  defp normalise(email), do: email |> String.trim() |> String.downcase()

  defp blank_to_nil(name) do
    case name |> String.trim() |> String.trim("\"") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
