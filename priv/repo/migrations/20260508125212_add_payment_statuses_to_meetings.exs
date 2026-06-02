defmodule Tymeslot.Repo.Migrations.AddPaymentStatusesToMeetings do
  use Ecto.Migration

  @moduledoc """
  Records the addition of `awaiting_payment` and `expired` to the meeting
  status enum. The DB column is plain varchar; this migration is a no-op
  at the SQL layer but documents the schema-level extension.
  """

  def change, do: :ok
end
