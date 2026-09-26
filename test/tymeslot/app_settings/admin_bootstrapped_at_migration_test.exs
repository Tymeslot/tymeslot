defmodule Tymeslot.AppSettings.AdminBootstrappedAtMigrationTest do
  @moduledoc """
  Drives `20260923101729_add_admin_bootstrapped_at_to_app_settings`: an
  install that already has users is marked as past its admin bootstrap, and a
  fresh one is left open for its first sign-up. See
  `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :auth

  import Ecto.Query, only: [from: 2]

  alias Tymeslot.AppSettings.AppSettingsSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_923_101_729

  test "marks an install with users as bootstrapped" do
    insert(:user)

    MigrationRunner.rerun!(@version)

    assert %DateTime{} = bootstrapped_at()
  end

  test "leaves a fresh install open for its first sign-up" do
    MigrationRunner.rerun!(@version)

    assert bootstrapped_at() == nil
  end

  test "recreates a missing settings row for an install with users" do
    insert(:user)
    Repo.delete_all(AppSettingsSchema)

    MigrationRunner.rerun!(@version)

    assert %DateTime{} = bootstrapped_at()
  end

  test "re-applying keeps a timestamp that is already set" do
    insert(:user)
    earlier = ~U[2026-01-02 03:04:05Z]

    Repo.update_all(from(s in AppSettingsSchema, where: s.id == 1),
      set: [admin_bootstrapped_at: earlier]
    )

    MigrationRunner.replay!(@version)

    assert bootstrapped_at() == earlier
  end

  defp bootstrapped_at do
    Repo.one(from(s in AppSettingsSchema, where: s.id == 1, select: s.admin_bootstrapped_at))
  end
end
