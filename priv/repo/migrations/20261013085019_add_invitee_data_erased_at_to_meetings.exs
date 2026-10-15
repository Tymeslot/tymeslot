defmodule Tymeslot.Repo.Migrations.AddInviteeDataErasedAtToMeetings do
  use Ecto.Migration

  @moduledoc """
  Adds `meetings.invitee_data_erased_at`, stamped once the retention purge
  (`Tymeslot.InviteeData.anonymise_expired/1`) has anonymised a meeting, so
  later runs pass over it. Nullable with no default, so existing rows need no
  backfill: every one of them still holds its invitee data.
  """

  def change do
    alter table(:meetings) do
      add :invitee_data_erased_at, :utc_datetime
    end
  end
end
