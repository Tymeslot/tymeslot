defmodule Tymeslot.CalendarGrid.EventVideoRoomSchema do
  @moduledoc """
  A video room made for an event created on the dashboard calendar grid, kept
  for providers whose rooms stay on the organiser's server until something
  deletes them (`ProviderConfig.rooms_deleted_after_meeting/0`).

  The event is addressed within `calendar_integration_id` by `event_uid`, the
  uid Tymeslot generated for it, and `provider_event_id`, the identifier the
  calendar provider returned when the event was written. Google and Outlook
  address an event by the latter, CalDAV servers by the former; see
  `Tymeslot.CalendarGrid.EventVideoRooms`. `provider_calendar_id` is the
  calendar the event was written to, which Google needs to look it up. `calendar_integration_id` is cleared
  if that integration goes.

  `video_integration_id` is cleared if the integration goes, as a meeting's is,
  and `provider` survives it so a reconnected integration can still reach the
  room.

  `lobby_opens_at` is when the room's lobby lets guests in. It follows a
  one-off event's start, and only ever moves earlier for an all-day event or a
  recurring series, which have no single start to wait for.

  `ends_at` is when the room stops being needed: the event's end, or for a
  recurring series a time no later occurrence can end after. It is nil when no
  such time is known, and the room is then kept until the event is deleted or
  the integration disconnected.
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
          provider: String.t() | nil,
          calendar_integration_id: integer() | nil,
          event_uid: String.t() | nil,
          provider_event_id: String.t() | nil,
          provider_calendar_id: String.t() | nil,
          room_id: String.t() | nil,
          lobby_opens_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          video_integration: VideoIntegrationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          calendar_integration:
            CalendarIntegrationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_event_video_rooms" do
    field(:provider, :string)
    field(:event_uid, :string)
    field(:provider_event_id, :string)
    field(:provider_calendar_id, :string)
    field(:room_id, :string)
    field(:lobby_opens_at, :utc_datetime)
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
      :provider,
      :calendar_integration_id,
      :event_uid,
      :provider_event_id,
      :provider_calendar_id,
      :room_id,
      :lobby_opens_at,
      :ends_at
    ])
    |> validate_required([:user_id, :provider, :event_uid, :room_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:video_integration_id)
    |> foreign_key_constraint(:calendar_integration_id)
  end
end
