defmodule Tymeslot.Repo.Migrations.AddCaseInsensitiveUniqueIndexesForEmailAndUsername do
  @moduledoc """
  Replaces the case-sensitive unique indexes on users.email and
  profiles.username with case-insensitive functional indexes on lower(...).

  Emails are downcased and usernames are constrained to lowercase in the
  changesets, so the DB previously relied entirely on app-layer normalisation.
  Any path that skips those changesets (backfills, console inserts, a future
  OAuth path) could create `Foo@x.com`/`foo@x.com` duplicates. The functional
  indexes enforce case-insensitive uniqueness at the DB level.

  The new indexes keep the original names (users_email_index,
  profiles_username_index) so the schemas' `unique_constraint(:email)` /
  `unique_constraint(:username)` keep matching without change.

  Self-healing: existing case-insensitive duplicates cannot be resolved
  automatically (we cannot pick which account/profile to keep), so the
  migration refuses to run and reports the collisions for manual merge rather
  than corrupting data.
  """

  use Ecto.Migration

  def up do
    execute(fn ->
      ensure_no_case_collisions("users", "email")
      ensure_no_case_collisions("profiles", "username")
    end)

    drop(unique_index(:users, [:email]))
    create(unique_index(:users, ["lower(email)"], name: :users_email_index))

    drop(unique_index(:profiles, [:username]))
    create(unique_index(:profiles, ["lower(username)"], name: :profiles_username_index))
  end

  def down do
    drop(unique_index(:profiles, [:username], name: :profiles_username_index))
    create(unique_index(:profiles, [:username]))

    drop(unique_index(:users, [:email], name: :users_email_index))
    create(unique_index(:users, [:email]))
  end

  defp ensure_no_case_collisions(table, column) do
    %{rows: rows} =
      repo().query!("""
      SELECT lower(#{column}) AS key, count(*) AS n
      FROM #{table}
      WHERE #{column} IS NOT NULL
      GROUP BY lower(#{column})
      HAVING count(*) > 1
      """)

    case rows do
      [] ->
        :ok

      collisions ->
        details = Enum.map_join(collisions, ", ", fn [key, n] -> "#{key} (#{n})" end)

        raise """
        Cannot add a case-insensitive unique index on #{table}.#{column}: \
        existing rows collide when lowercased — #{details}. \
        Merge or remove the duplicate rows, then re-run the migration. \
        (These cannot be resolved automatically because the migration cannot \
        decide which row to keep.)
        """
    end
  end
end
