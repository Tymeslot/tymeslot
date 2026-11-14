defmodule Tymeslot.Repo.Migrations.CreateUserSmtpSettingsTest do
  @moduledoc "Exercises the shipped SMTP migration against the previous schema."

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Test.MigrationRunner

  @version 20_261_109_201_325

  test "the additive migration can roll back and reapply without touching existing users" do
    user = insert(:user)

    MigrationRunner.rerun!(@version)

    assert Repo.get!(Tymeslot.Auth.UserSchema, user.id).email == user.email
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM user_smtp_settings")

    assert %{rows: [[false]]} =
             Repo.query!("""
             SELECT column_default::boolean FROM information_schema.columns
             WHERE table_name = 'user_smtp_settings' AND column_name = 'enabled'
             """)
  end
end
