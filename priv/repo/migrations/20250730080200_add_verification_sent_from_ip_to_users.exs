defmodule Tymeslot.Repo.Migrations.AddVerificationSentFromIpToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :verification_sent_from_ip, :string
    end
  end
end
