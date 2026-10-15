defmodule Tymeslot.Emails.Shared.GroupSession do
  @moduledoc """
  The line that tells a group participant their booking is a spot in a
  group session, not a meeting of their own.

  A participant's emails are otherwise worded like a one-to-one booking's,
  which reads as if the host were meeting them alone. The line names how
  many people the session takes and nobody else on it: the other
  participants' names are theirs, not this participant's to see.

  `nil` for a payload whose meeting is not a group meeting (`:capacity`
  missing or 1), so a one-to-one email renders exactly as it did.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "The line for `details`, in the current Gettext locale, or `nil`."
  @spec line(map()) :: String.t() | nil
  def line(%{capacity: capacity}) when is_integer(capacity) and capacity > 1 do
    dngettext(
      "emails",
      "Group session: you have one of %{count} spot.",
      "Group session: you have one of %{count} spots.",
      capacity,
      count: capacity
    )
  end

  def line(_details), do: nil

  @doc "The line as a plain-text paragraph (with its trailing blank line), or `\"\"`."
  @spec text(map()) :: String.t()
  def text(details) do
    case line(details) do
      nil -> ""
      line -> "#{line}\n\n"
    end
  end
end
