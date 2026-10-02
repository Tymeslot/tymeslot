defmodule Tymeslot.Repo.Migrations.ClearSignupIpOfVerifiedUsers do
  use Ecto.Migration

  @moduledoc """
  Clears `users.signup_ip` on every account that is already verified.

  The sign-up address is kept only for the same-device check when the
  verification link is followed. From this release verifying an account
  clears it, but accounts verified before then still carry theirs, and would
  for as long as the account exists. This brings them in line.

  Unverified accounts keep theirs: their verification link may still be
  followed, and the check needs it.

  Irreversible in substance: the addresses are gone, so `down/0` does
  nothing, and running `up/0` again finds nothing left to clear.
  """

  def up do
    # A one-shot data cleanup over a nullable column; there is no migration DSL
    # form for it, and it adds no constraint for existing rows to violate.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE users
    SET signup_ip = NULL
    WHERE verified_at IS NOT NULL AND signup_ip IS NOT NULL
    """)
  end

  def down, do: :ok
end
