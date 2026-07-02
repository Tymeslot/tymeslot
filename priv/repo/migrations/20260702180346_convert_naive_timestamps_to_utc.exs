defmodule Tymeslot.Repo.Migrations.ConvertNaiveTimestampsToUtc do
  @moduledoc """
  Converts inserted_at/updated_at from `timestamp without time zone` to
  `timestamptz` on tables that used a bare `timestamps()` (naive) call. The
  matching schemas now declare `timestamps(type: :utc_datetime)`, so the
  column type must follow or every read/compare against a DateTime would clash.

  Existing naive values were written by Ecto's default `timestamps()` as UTC
  wall-clock, so `col AT TIME ZONE 'UTC'` reinterprets them as the correct
  instant losslessly. The reverse is symmetric.

  Each ALTER rewrites its table under an ACCESS EXCLUSIVE lock. These are the
  smaller/owner-scoped tables; the large provider_calendar_events cache is
  converted in a separate migration so an operator can schedule it apart.
  """

  use Ecto.Migration

  # Tables carrying both inserted_at and updated_at.
  @both ~w(
    connect_accounts
    users
    theme_customizations
    user_sessions
    meeting_types
    booking_payments
    video_integrations
    calendar_integrations
    profiles
    availability_breaks
    availability_overrides
    weekly_availability
    calendar_preferences
  )

  # Tables carrying only inserted_at (timestamps(updated_at: false)).
  @inserted_only ~w(webhook_events)

  def up do
    for table <- @both, col <- ~w(inserted_at updated_at) do
      convert(table, col, "timestamptz", "UTC")
    end

    for table <- @inserted_only do
      convert(table, "inserted_at", "timestamptz", "UTC")
    end
  end

  def down do
    for table <- @both, col <- ~w(inserted_at updated_at) do
      convert(table, col, "timestamp", "UTC")
    end

    for table <- @inserted_only do
      convert(table, "inserted_at", "timestamp", "UTC")
    end
  end

  defp convert(table, col, type, zone) do
    execute(
      "ALTER TABLE #{table} ALTER COLUMN #{col} TYPE #{type} USING #{col} AT TIME ZONE '#{zone}'"
    )
  end
end
