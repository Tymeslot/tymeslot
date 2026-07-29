defmodule Tymeslot.Integrations.Video.MeetingContext do
  @moduledoc """
  In-memory context returned by `ProviderAdapter.create_meeting_room/2`,
  threading a provider's `RoomData` through join-URL and lifecycle-event
  calls.
  """

  alias Tymeslot.Integrations.Video.RoomData

  @enforce_keys [:provider_type, :room_data, :provider_module]
  defstruct [:provider_type, :room_data, :provider_module]

  @type t :: %__MODULE__{
          provider_type: atom(),
          room_data: RoomData.t(),
          provider_module: module()
        }
end
