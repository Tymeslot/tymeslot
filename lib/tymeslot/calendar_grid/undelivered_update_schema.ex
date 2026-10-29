defmodule Tymeslot.CalendarGrid.UndeliveredUpdateSchema do
  @moduledoc """
  A guest of a dashboard calendar event whose latest update email could not
  be delivered (`Tymeslot.CalendarGrid.UndeliveredUpdates`).

  The event is addressed within `calendar_integration_id` by `event_uid`, the
  uid its cached row carries, which is the uid the update email job names.
  `failed_at` is when the most recent attempt to email `email` failed.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          calendar_integration_id: integer() | nil,
          event_uid: String.t() | nil,
          email: String.t() | nil,
          failed_at: DateTime.t() | nil,
          calendar_integration:
            CalendarIntegrationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_event_undelivered_updates" do
    field(:event_uid, :string)
    field(:email, :string)
    field(:failed_at, :utc_datetime)

    belongs_to(:calendar_integration, CalendarIntegrationSchema)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset recording a failed update email to one guest."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:calendar_integration_id, :event_uid, :email, :failed_at])
    |> validate_required([:calendar_integration_id, :event_uid, :email, :failed_at])
    |> foreign_key_constraint(:calendar_integration_id)
  end
end
