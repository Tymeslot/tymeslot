defmodule Tymeslot.CalendarGrid.EventVideoRoomSchema do
  @moduledoc """
  A video room made for an event created on the dashboard calendar grid, kept
  for providers whose rooms stay on the organiser's server until something
  deletes them (`ProviderConfig.rooms_deleted_after_meeting/0`).

  The event is addressed by `calendar_integration_id` and `event_uid`, the pair
  that identifies it in the event cache. `calendar_integration_id` is cleared if
  that integration goes, which leaves the room to expire rather than dropping
  the row.

  `starts_at` is the start the room's lobby waits for. It is nil when the event
  has no single start to wait for: an all-day event or a recurring series.

  `ends_at` is when the room stops being needed: the event's end, or for a
  recurring series a time no later occurrence can end after. It is nil for a
  series with no end, whose room is kept until the event is deleted or the
  integration disconnected.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          video_integration_id: integer() | nil,
          calendar_integration_id: integer() | nil,
          event_uid: String.t() | nil,
          room_id: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          video_integration: VideoIntegrationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_event_video_rooms" do
    field(:event_uid, :string)
    field(:room_id, :string)
    field(:starts_at, :utc_datetime)
    field(:ends_at, :utc_datetime)

    belongs_to(:user, UserSchema)
    belongs_to(:video_integration, VideoIntegrationSchema)
    belongs_to(:calendar_integration, CalendarIntegrationSchema)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for recording a newly made room.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :user_id,
      :video_integration_id,
      :calendar_integration_id,
      :event_uid,
      :room_id,
      :starts_at,
      :ends_at
    ])
    |> validate_required([:user_id, :video_integration_id, :event_uid, :room_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:video_integration_id)
    |> foreign_key_constraint(:calendar_integration_id)
  end
end
