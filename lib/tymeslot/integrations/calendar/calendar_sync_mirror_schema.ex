defmodule Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema do
  @moduledoc """
  The mapping from one source event to the placeholder written for it on the
  target calendar, plus the provider bookkeeping needed to decide whether a
  re-write is required.

  Deliberately its own table rather than a tag on the event cache.
  `provider_calendar_events.provider_metadata` is the only map column there and
  it is listed in `replace_fields/0`
  (`Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries`), so every
  inbound sync overwrites it wholesale with the raw provider payload. A mapping
  stored there would survive until the next sync and then vanish, taking with
  it the only record of which provider event to update or delete — and leaving
  an orphaned placeholder on the target that nothing owns and nothing will ever
  clean up. The cache is a projection of provider state; this is Tymeslot's own
  bookkeeping and needs storage that sync does not clobber.

  `target_integration_id` is denormalised from the link. The engine reads this
  table forwards, from a link and a source UID; the calendar grid reads it
  backwards, holding UIDs cached against one target integration and asking
  which of them are mirrors it should hide. Without the column the target is
  reachable only by joining through the link, so the backwards question cannot
  be indexed and degrades to a sequential scan on every grid render — and the
  grid re-renders on navigation, on live cache updates, and on every appearance
  change.

  `state` is not a substitute for the row's existence. `pending_delete` marks a
  mirror whose source is gone but whose placeholder is still on the provider:
  deleting the row first would lose the `target_provider_event_id` needed to
  remove it, so the row outlives the source and is dropped only once the
  provider confirms the delete.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema

  @states ~w(active pending_delete failed)

  @type t :: %__MODULE__{
          id: integer() | nil,
          sync_link_id: integer() | nil,
          source_uid: String.t() | nil,
          target_integration_id: integer() | nil,
          target_provider_event_id: String.t() | nil,
          target_uid: String.t() | nil,
          source_updated_at: DateTime.t() | nil,
          source_etag: String.t() | nil,
          target_etag: String.t() | nil,
          last_synced_at: DateTime.t() | nil,
          state: String.t(),
          sync_link: CalendarSyncLinkSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          target_integration:
            CalendarIntegrationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_sync_mirrors" do
    field(:source_uid, :string)
    field(:target_provider_event_id, :string)
    field(:target_uid, :string)
    field(:source_updated_at, :utc_datetime_usec)
    field(:source_etag, :string)
    field(:target_etag, :string)
    field(:last_synced_at, :utc_datetime_usec)
    field(:state, :string, default: "active")

    belongs_to(:sync_link, CalendarSyncLinkSchema)
    belongs_to(:target_integration, CalendarIntegrationSchema)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the lifecycle states a mirror row may hold.

  `active` is a placeholder in step with its source, `pending_delete` a
  placeholder whose source is gone but which is still on the provider, and
  `failed` one whose last write did not land.
  """
  @spec states() :: [String.t()]
  def states, do: @states

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :sync_link_id,
      :source_uid,
      :target_integration_id,
      :target_provider_event_id,
      :target_uid,
      :source_updated_at,
      :source_etag,
      :target_etag,
      :last_synced_at,
      :state
    ])
    |> validate_required([:sync_link_id, :source_uid, :target_integration_id, :target_uid])
    |> validate_inclusion(:state, @states)
    |> foreign_key_constraint(:sync_link_id)
    |> foreign_key_constraint(:target_integration_id)
    |> unique_constraint([:sync_link_id, :source_uid],
      name: :calendar_sync_mirrors_link_source_uid_index,
      message: "is already mirrored by this link"
    )
  end
end
