defmodule Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema do
  @moduledoc """
  One recorded resolution of a mirror divergence: both sides changed, the
  mirror was edited on the host, a delete raced an update, or the write failed
  outright.

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

  @kinds ~w(both_changed mirror_edited delete_race write_failed)
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
