defmodule Tymeslot.Meetings.UniqueIndex do
  @moduledoc """
  The one test shared by the meeting unique indexes (`Tymeslot.Meetings.UniqueSlot`,
  `Tymeslot.Meetings.UniqueInvitation`): whether a changeset carries the error
  Ecto records when a named unique index refused the write.
  """

  @doc "True when any error on the changeset is a violation of the unique index `name`."
  @spec violated?(Ecto.Changeset.t(), atom()) :: boolean()
  def violated?(%Ecto.Changeset{errors: errors}, name) do
    expected = Atom.to_string(name)

    Enum.any?(errors, fn {_field, {_message, error_opts}} ->
      error_opts[:constraint] == :unique and
        to_string(error_opts[:constraint_name] || "") == expected
    end)
  end
end
