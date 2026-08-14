defmodule Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema do
  @moduledoc """
  One recorded resolution of a mirror divergence: both sides changed, the
  mirror was edited on the host, a delete raced an update, or the write failed
  outright.

  `occurrence_moved` is a fifth, and differs from those four in what it is
  about. They each record a resolution the engine *reached*; this one records a
  divergence it has decided not to resolve. A single occurrence of a mirrored
  series dragged to another time leaves the placeholder wrong in both
  directions — the slot the occurrence left is still blocked, and the slot it
  moved to is not — and correcting that needs per-instance overrides that were
  costed and deferred. `SyncLink.MovedOccurrence` writes it, on evidence no
  other kind has: the per-instance `originalStartTime`, read before the cache
  collapses the series to one row.

  `series_exceptions` is a sixth kind that is **still valid but no longer
  written**. It recorded a mirrored series whose master carried `EXDATE` lines
  the placeholder did not reflect, from the stage when a recurring source was
  mirrored from its RRULE alone: the placeholder went on blocking occurrences
  the organiser had cancelled, and the row was how they found out. The
  placeholder now carries those `EXDATE` lines, so the gap it described is
  closed and `SyncLink.ConflictLog` produces no more of them.

  It stays in `@kinds` because this table is append-only and rows written before
  that fix are still true about the placeholders of their time. Dropping the
  kind would not remove them; it would leave them rendering under the
  dashboard's catch-all, which describes them worse than the name they were
  written with. `occurrence_moved` is deliberately **not** a revival of it:
  that name and its label are about cancelled occurrences a placeholder failed
  to exclude, which is over-blocking and now fixed, while a move is a block in
  the wrong place. Recording a move under it would make the historical rows and
  the new ones mean two different things under one name.

  Append-only, and separate from the mirror row on purpose. A mirror holds
  current state and is overwritten on every successful write, so a conflict
  noted there is erased by the very next sync — which is precisely when an
  organiser starts asking why their placeholder moved or why it disappeared.
  The history has to outlive the state that produced it or it answers nothing.

  `occurred_at` is distinct from `inserted_at` because a conflict found during
  a reconciliation sweep happened when the two sides diverged, not when the
  sweep noticed. Ordering an organiser's history by insertion would interleave
  hours-old divergences with live ones and make the sequence unreadable.

  `detail` is a free-form map rather than typed columns: a useful conflict
  record is whatever the branch that produced it had in hand — the timestamps
  and etags compared, or the provider error — and pinning columns would mean a
  migration for every new conflict kind.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema

  @kinds ~w(both_changed mirror_edited delete_race write_failed occurrence_moved series_exceptions)
  @resolutions ~w(source_won deletion_won skipped)

  @type t :: %__MODULE__{
          id: integer() | nil,
          sync_link_id: integer() | nil,
          source_uid: String.t() | nil,
          kind: String.t() | nil,
          resolution: String.t() | nil,
          detail: map(),
          occurred_at: DateTime.t() | nil,
          sync_link: CalendarSyncLinkSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_sync_conflicts" do
    field(:source_uid, :string)
    field(:kind, :string)
    field(:resolution, :string)
    field(:detail, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    belongs_to(:sync_link, CalendarSyncLinkSchema)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the divergences the engine knows how to record."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Returns the outcomes a recorded divergence may have been resolved to."
  @spec resolutions() :: [String.t()]
  def resolutions, do: @resolutions

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(conflict, attrs) do
    conflict
    |> cast(attrs, [:sync_link_id, :source_uid, :kind, :resolution, :detail, :occurred_at])
    |> put_occurred_at()
    |> validate_required([:sync_link_id, :source_uid, :kind, :resolution, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:resolution, @resolutions)
    |> foreign_key_constraint(:sync_link_id)
  end

  # The caller supplies occurred_at when the divergence is older than its
  # discovery — a reconciliation sweep knows the source's own timestamp. When
  # it does not, "now" is correct and defaulting here keeps every call site
  # from repeating it and one of them from forgetting.
  defp put_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now())
      _occurred_at -> changeset
    end
  end
end
