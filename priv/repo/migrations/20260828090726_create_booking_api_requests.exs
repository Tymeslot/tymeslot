defmodule Tymeslot.Repo.Migrations.CreateBookingApiRequests do
  @moduledoc """
  One row per idempotency key presented to the booking API.

  The row is the caller's claim on a key, inserted before the booking is
  attempted and carrying `meeting_id` once it succeeds. That ordering is the
  whole point: the unique index on `(user_id, idempotency_key)` is what lets
  two concurrent retries of the same request resolve to a single booking
  instead of two meetings for the same attendee.

  Keys are scoped to the organiser, so two callers integrating with two
  different organisers cannot collide, and neither can discover the other's
  keys by guessing.

  `meeting_id` is nullable because it is unknown while the booking is in
  flight, and deleting the meeting deletes its claim: once the meeting is gone
  there is nothing left to replay, and a caller retrying the key should be
  allowed to book afresh.
  """
  # The references and index below are created against a table this same
  # migration creates: it holds no rows yet, so there is no lock contention or
  # table rewrite to avoid by adding them concurrently or in a later migration.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  use Ecto.Migration

  def change do
    create table(:booking_api_requests) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:idempotency_key, :string, null: false)
      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all))

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:booking_api_requests, [:user_id, :idempotency_key]))
    create(index(:booking_api_requests, [:meeting_id]))
  end
end
