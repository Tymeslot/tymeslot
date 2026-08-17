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

  `target_calendar_id` records which calendar *within* that integration the
  placeholder actually landed on, and it is not the same question as
  `target_integration_id`. Google and Outlook honour a `calendar_id` on write,
  so a link naming a secondary calendar puts its placeholders there rather than
  on the integration's default booking calendar. Every write and delete used to
  build that id from the link's *current* `target_calendar_id`, which holds only
  while the link never moves: re-pointing a link leaves the existing
  placeholders where they were and makes the delete address a calendar that
  never held them, drawing a 404 read as "already gone" — the row dropped, the
  busy block stranded with nothing able to name it.

  `nil` means "wherever the link points" rather than "no calendar", which is
  what makes the column safe to add without a backfill: it is what every row
  written before it holds, and what the delete paths already did for them. It is
  also the permanently correct value for a CalDAV target, which ignores
  `calendar_id` and always writes to the primary path.

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

  # Each state is named once and referenced everywhere it is written or matched,
  # rather than spelled as a literal at each site. The engine's withdrawal guard
  # (`SyncLink.Engine.update_mirror/7`) matches `@state_pending_delete` in a
  # *function head*, and that is what makes the naming a correctness measure
  # rather than tidiness: a misspelt literal there does not raise, it simply
  # fails to match and falls through to the next clause — which rewrites the
  # placeholder a teardown is mid-way through withdrawing, the exact race that
  # clause exists to prevent. A misspelt attribute is a compile error.
  @state_active "active"
  @state_pending_delete "pending_delete"
  @state_failed "failed"

  @states [@state_active, @state_pending_delete, @state_failed]

  @type t :: %__MODULE__{
          id: integer() | nil,
          sync_link_id: integer() | nil,
          source_uid: String.t() | nil,
          target_integration_id: integer() | nil,
          target_calendar_id: String.t() | nil,
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
    field(:target_calendar_id, :string)
    field(:target_provider_event_id, :string)
    field(:target_uid, :string)
    field(:source_updated_at, :utc_datetime_usec)
    field(:source_etag, :string)
    field(:target_etag, :string)
    field(:last_synced_at, :utc_datetime_usec)
    field(:state, :string, default: @state_active)

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

  @doc """
  A placeholder in step with its source.
  """
  @spec state_active() :: String.t()
  def state_active, do: @state_active

  @doc """
  A placeholder whose source is gone but which is still on the provider.

  Set by a teardown whose provider delete did not land, and the one state the
  reconcile sweep hunts for on an otherwise disabled link.
  """
  @spec state_pending_delete() :: String.t()
  def state_pending_delete, do: @state_pending_delete

  @doc """
  A placeholder whose last write did not land.
  """
  @spec state_failed() :: String.t()
  def state_failed, do: @state_failed

  @doc """
  Where this placeholder lives, in the shape the delete and colour-patch opts
  take, falling back to `link` when the row records nothing.

  Both the sync path and teardown ask this, and they must agree: they take turns
  on the same placeholder, teardown attempting the delete and the reconcile
  sweep retrying whatever it could not finish. Two readings of the fallback is
  how the first attempt and its retry end up addressing different calendars.

  The fallback is the whole reason this is not a bare field read. `nil` means
  "wherever the link points" — see the moduledoc — so a row written before the
  column existed keeps being deleted exactly as it was, from the link's current
  calendar, rather than from no calendar at all.
  """
  @spec target_calendar_opts(t(), CalendarSyncLinkSchema.t()) :: keyword()
  def target_calendar_opts(%__MODULE__{target_calendar_id: nil}, link),
    do: link_calendar_opts(link)

  def target_calendar_opts(%__MODULE__{target_calendar_id: calendar_id}, _link),
    do: [calendar_id: calendar_id]

  # An empty list is the correct instruction for a link naming no calendar, not
  # a missing one: such a link writes to the target integration's default
  # booking calendar, which is where a call naming none already goes.
  defp link_calendar_opts(%CalendarSyncLinkSchema{target_calendar_id: nil}), do: []

  defp link_calendar_opts(%CalendarSyncLinkSchema{target_calendar_id: calendar_id}),
    do: [calendar_id: calendar_id]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :sync_link_id,
      :source_uid,
      :target_integration_id,
      :target_calendar_id,
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
    # The database enforces the same set, because `update_all` writes bypass
    # this changeset entirely. Naming it here turns the raise into an error on
    # the field for anything that does come through the changeset, so the two
    # layers report the same failure the same way.
    |> check_constraint(:state,
      name: :calendar_sync_mirrors_state_check,
      message: "is invalid"
    )
    |> foreign_key_constraint(:sync_link_id)
    |> foreign_key_constraint(:target_integration_id)
    |> unique_constraint([:sync_link_id, :source_uid],
      name: :calendar_sync_mirrors_link_source_uid_index,
      message: "is already mirrored by this link"
    )
  end
end
