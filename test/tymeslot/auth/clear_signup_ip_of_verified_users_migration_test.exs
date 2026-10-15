defmodule Tymeslot.Auth.ClearSignupIpOfVerifiedUsersMigrationTest do
  @moduledoc """
  Drives `20261002051715_clear_signup_ip_of_verified_users`: verified
  accounts lose the sign-up address they no longer need, while an unverified
  account keeps the one its pending verification link is checked against.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :auth

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_002_051_715

  test "clears signup_ip on verified accounts only" do
    verified = insert(:user, signup_ip: "203.0.113.7")
    pending = insert(:unverified_user, signup_ip: "198.51.100.4")

    MigrationRunner.replay!(@version)

    assert Repo.reload!(verified).signup_ip == nil
    assert Repo.reload!(pending).signup_ip == "198.51.100.4"
  end
end
