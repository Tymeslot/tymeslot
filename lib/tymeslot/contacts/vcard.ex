defmodule Tymeslot.Contacts.VCard do
  @moduledoc """
  Reads the name and email addresses out of a vCard (RFC 6350, and the 3.0
  cards older servers still hold).

  Only `FN` and `EMAIL` are read, which is all a contact suggestion shows.
  Folded lines are unfolded first (a line break followed by a space or tab
  continues the line before it), a property may carry a group prefix
  (`item1.EMAIL`) and parameters (`EMAIL;TYPE=work`), and text values are
  unescaped (`\\,`, `\;`, `\\n`, `\\\\`). Anything else on the card is
  ignored, and a card that is not one yields nothing rather than an error.
  """

  @type t :: %{name: String.t() | nil, emails: [String.t()]}

  @doc "The card's formatted name and its email addresses, in card order."
  @spec parse(String.t()) :: t()
  def parse(text) when is_binary(text) do
    text
    |> unfold()
    |> String.split(~r/\r\n|\n|\r/)
    |> Enum.reduce(%{name: nil, emails: []}, &read_line/2)
    |> Map.update!(:emails, &(&1 |> Enum.reverse() |> Enum.uniq()))
  end

  def parse(_text), do: %{name: nil, emails: []}

  defp unfold(text), do: String.replace(text, ~r/(\r\n|\n|\r)[ \t]/, "")

  defp read_line(line, card) do
    with [head, value] <- String.split(line, ":", parts: 2),
         property when property in ["FN", "EMAIL"] <- property_name(head) do
      put(card, property, unescape(String.trim(value)))
    else
      _other -> card
    end
  end

  # `item1.EMAIL;TYPE=work` → `EMAIL`. Property names are case-insensitive.
  defp property_name(head) do
    head
    |> String.split(";", parts: 2)
    |> hd()
    |> String.split(".")
    |> List.last()
    |> String.upcase()
  end

  defp put(card, _property, ""), do: card
  defp put(%{name: nil} = card, "FN", name), do: %{card | name: name}
  defp put(card, "FN", _name), do: card

  defp put(card, "EMAIL", email) do
    email = email |> String.replace_prefix("mailto:", "") |> String.downcase()
    %{card | emails: [email | card.emails]}
  end

  defp unescape(value) do
    Regex.replace(~r/\\(.)/, value, fn
      _whole, "n" -> " "
      _whole, "N" -> " "
      _whole, char -> char
    end)
  end
end
