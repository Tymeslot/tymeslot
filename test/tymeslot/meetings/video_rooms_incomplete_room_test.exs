defmodule Tymeslot.Meetings.VideoRoomsIncompleteRoomTest do
  @moduledoc """
  Regression test for the persistence guard in
  `Tymeslot.Meetings.VideoRooms.add_video_room_to_meeting/1`.

  A provider that answers successfully but returns neither a room id nor a
  meeting URL has produced nothing joinable. Before this guard existed, the
  fallback room id `"unknown"` was persisted alongside `video_room_enabled:
  true`, `meeting_url: nil` and join links pointing at an empty room, so the
  booking looked like it had video when it did not.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()

    original_video_module = Application.get_env(:tymeslot, :video_module)
    Application.put_env(:tymeslot, :video_module, __MODULE__.RoomlessVideoModule)

    on_exit(fn ->
      case original_video_module do
        nil -> Application.delete_env(:tymeslot, :video_module)
        mod -> Application.put_env(:tymeslot, :video_module, mod)
      end
    end)

    :ok
  end

  describe "add_video_room_to_meeting/1 with an unidentifiable room" do
    test "refuses the room and leaves the meeting untouched" do
      meeting = build_mirotalk_scenario()

      assert {:error, :incomplete_video_room} =
               VideoRooms.add_video_room_to_meeting(meeting.id)

      unchanged = Repo.get(MeetingSchema, meeting.id)
      refute unchanged.video_room_enabled
      assert is_nil(unchanged.video_room_id)
      assert is_nil(unchanged.organizer_video_url)
      assert is_nil(unchanged.attendee_video_url)

      refute_enqueued(worker: CalendarEventWorker)
    end
  end

  defp build_mirotalk_scenario do
    user = insert(:user)
    _profile = insert(:profile, user: user)

    integration =
      insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

    insert(:meeting,
      organizer_user_id: user.id,
      organizer_email: user.email,
      video_integration_id: integration.id,
      video_room_id: nil,
      video_room_enabled: false
    )
  end

  defmodule RoomlessVideoModule do
    @moduledoc """
    Stands in for `Tymeslot.Integrations.Video`, returning a meeting context
    that carries no room id and no meeting URL.
    """

    @spec create_meeting_room(integer() | nil, keyword()) :: {:ok, map()}
    def create_meeting_room(_user_id, _opts) do
      {:ok,
       %{
         provider_type: :mirotalk,
         room_data: %{provider_data: %{"unexpected" => "data"}},
         provider_module: Tymeslot.Integrations.Video.Providers.MiroTalkProvider
       }}
    end

    @spec create_join_url(map(), String.t(), String.t(), String.t(), DateTime.t()) ::
            {:ok, String.t()}
    def create_join_url(_ctx, _name, _email, role, _start_time) do
      {:ok, "https://video.example.com/join?role=#{role}&room="}
    end

    @spec extract_room_id(map() | String.t()) :: String.t() | nil
    defdelegate extract_room_id(input), to: Tymeslot.Integrations.Video.Urls
  end
end
