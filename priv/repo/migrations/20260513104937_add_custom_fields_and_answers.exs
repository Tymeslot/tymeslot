defmodule Tymeslot.Repo.Migrations.AddCustomFieldsAndAnswers do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add(:custom_fields, {:array, :map}, default: [], null: false)
    end

    alter table(:meetings) do
      add(:custom_fields_snapshot, {:array, :map}, default: [], null: false)
      add(:custom_field_answers, :map, default: %{}, null: false)
    end
  end
end
