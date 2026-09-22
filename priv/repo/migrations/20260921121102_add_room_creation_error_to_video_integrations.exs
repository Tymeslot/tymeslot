defmodule Tymeslot.Repo.Migrations.AddRoomCreationErrorToVideoIntegrations do
  use Ecto.Migration

  @moduledoc """
  Records why a video provider refuses to create rooms for an integration.

  A server can accept an integration's credentials and still refuse every room
  (a Nextcloud that limits who may create conversations, or enforces a
  password on public ones). Bookings then go out without a link, so the
  refusal is kept on the integration for its dashboard row to explain:

    * `room_creation_error`: the refusal's code, cleared once a room is
      created again or the connection is changed and proven
    * `room_creation_error_since`: when that refusal was first seen
    * `room_creation_errors_notified`: every code the owner has already been
      emailed about, so each is emailed at most once

  Existing rows have seen no refusal, so the two nullable columns start empty
  and the list starts as an empty array.
  """

  # PostgreSQL 11+ stores a non-volatile default in the catalogue rather than
  # rewriting the table, so this is a metadata-only change. Migrations also run
  # offline here (`start.sh` runs them in a one-shot VM and only starts Phoenix
  # once they finish), so no live traffic waits on the lock either way.
  def change do
    alter table(:video_integrations) do
      add(:room_creation_error, :string)
      add(:room_creation_error_since, :utc_datetime)
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:room_creation_errors_notified, {:array, :string}, null: false, default: [])
    end
  end
end
