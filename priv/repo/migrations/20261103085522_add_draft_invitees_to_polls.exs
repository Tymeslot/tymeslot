defmodule Tymeslot.Repo.Migrations.AddDraftInviteesToPolls do
  use Ecto.Migration

  @moduledoc """
  Adds `polls.draft_invitees`: the people a host has listed on a draft poll,
  held until the poll is published. Only then are they made participants and
  emailed, so a draft sends nothing and spends none of the host's poll email
  allowance.

  Nullable with no default: every existing poll is already published and has
  nobody waiting. A draft's `status` is the new `"draft"` value of the existing
  string column, which needs no change.
  """

  def change do
    alter table(:polls) do
      add :draft_invitees, {:array, :map}
    end
  end
end
