defmodule Tymeslot.Integrations.Video.RoomData do
  @moduledoc """
  Structured result of a video provider's `create_meeting_room/1` callback.

  Built once by the provider (always atom-keyed, since it only ever lives in
  memory — there is no database column or JSON round-trip anywhere in this
  pipeline) and threaded through join-URL, lifecycle-event, and metadata
  calls via `MeetingContext`.
  """

  @enforce_keys [:room_id, :meeting_url, :provider_data]
  defstruct room_id: nil, meeting_url: nil, provider_data: nil, provider_config: nil

  @type t :: %__MODULE__{
          room_id: String.t() | nil,
          meeting_url: String.t() | nil,
          provider_data: map(),
          provider_config: map() | nil
        }
end
