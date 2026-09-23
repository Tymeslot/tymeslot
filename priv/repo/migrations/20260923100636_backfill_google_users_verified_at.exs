defmodule Tymeslot.Repo.Migrations.BackfillGoogleUsersVerifiedAt do
  @moduledoc """
  Marks accounts created through Google sign-in as verified.

  Social sign-up never recorded a verified email: every OAuth account has
  `verified_at` NULL, and sign-in now refuses a session to an unverified
  account until its owner follows an emailed link. Google accounts can be
  vouched for retroactively: Google sign-up always took its address from
  Google, and Google returns only addresses it has verified for its own
  accounts, so the address was proven when the account was created. A Google
  account can carry an address from another domain that Google never
  verified; such an account is rare, and was already signed in on the
  strength of that address, so it is not singled out here.

  GitHub and SSO accounts stay unverified. Their address may have been typed
  on the complete-registration form, and nothing on record tells those apart
  from a provider-supplied one (`provider_email`, which could have, was never
  populated). They are verified at their next sign-in when the provider
  vouches for the address on record, and asked to verify by email otherwise.
  """
  use Ecto.Migration

  # A backfill is the point of this migration, and it only fills a NULL the
  # sign-up code should have set.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  def up do
    execute("""
    UPDATE users
    SET verified_at = inserted_at
    WHERE verified_at IS NULL
      AND google_user_id IS NOT NULL
    """)
  end

  # The rows this touched are indistinguishable from accounts verified since,
  # so there is nothing safe to undo.
  def down, do: :ok
end
