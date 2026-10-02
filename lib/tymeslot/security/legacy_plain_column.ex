defmodule Tymeslot.Security.LegacyPlainColumn do
  @moduledoc """
  Keeps the plain-text predecessor of an encrypted field from going stale.

  Some values moved from a plain column into an encrypted one (see
  `Tymeslot.Security.EncryptedString`), with the plain column kept, value
  and all, so that rolling the image back to the previous release, which
  reads only the plain column, still finds it. Nothing writes the plain
  column any more, so once the encrypted value changes the plain copy is out
  of date, and a rollback would bring back a value the user replaced or
  removed: a regenerated free/busy token, a webhook URL that was edited away.

  A schema with such a column therefore maps a field onto it,

      field(:legacy_url, :string, source: :url, load_in_query: false, redact: true)

  and runs `clear_on_change/2` over every changeset that can change the
  encrypted field. Whenever that field changes the plain copy is emptied in the
  same write, so a rollback finds no value rather than an old one; a row that
  never changes keeps its copy, and with it the rollback.

  The field is never loaded, so it always reads `nil`: `Ecto.Changeset.put_change/3`
  would see no change in setting it to `nil`, which is why the copy is cleared
  with `force_change/3`. Delete this module along with the plain columns.
  """

  alias Ecto.Changeset

  @doc """
  Empties each legacy plain column in `copies` (`encrypted_field:
  legacy_field`) whose encrypted field changes in `changeset`.
  """
  @spec clear_on_change(Changeset.t(), keyword(atom())) :: Changeset.t()
  def clear_on_change(%Changeset{} = changeset, copies) when is_list(copies) do
    Enum.reduce(copies, changeset, fn {field, legacy_field}, acc ->
      if Changeset.changed?(acc, field),
        do: Changeset.force_change(acc, legacy_field, nil),
        else: acc
    end)
  end
end
