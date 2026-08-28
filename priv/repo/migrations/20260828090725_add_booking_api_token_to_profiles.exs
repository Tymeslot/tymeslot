defmodule Tymeslot.Repo.Migrations.AddBookingApiTokenToProfiles do
  # The index is built over a column this same migration adds, so every row is
  # NULL and there is nothing to compare. The build is a brief exclusive lock on
  # `profiles` — one row per account — rather than the scan a populated column
  # would need, which is why it is not created concurrently.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  use Ecto.Migration

  # Nullable secret token for the booking API (POST /api/v1/bookings). NULL
  # means the endpoint is closed for that profile. Unique so a presented token
  # maps to exactly one organiser.
  def change do
    alter table(:profiles) do
      add :booking_api_token, :string
    end

    # The column is brand-new and nullable; every existing row is NULL and
    # Postgres permits unlimited NULLs under a unique index, so no
    # data-preparation step is needed. `create_if_not_exists` keeps the
    # migration idempotent for partially-applied states.
    create_if_not_exists unique_index(:profiles, [:booking_api_token])
  end
end
