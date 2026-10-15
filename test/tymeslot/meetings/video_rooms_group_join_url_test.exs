defmodule Tymeslot.Meetings.VideoRoomsGroupJoinUrlTest do
  @moduledoc """
  A group meeting's slot row carries no attendee, so its participant link
  cannot name one. It is minted through the provider's identity-free
  `shared_join_url/2`, the link every seat holder shares, rather than by
  passing a nil name to `create_join_url/5`, which Zoom and Teams used to
  raise on: every group booking then logged an error and fell back to the
  room URL.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :video

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @room_url "https://video.example.com/join/a1b2c3d4e5f67890"
  @shared_url "https://video.example.com/join/a1b2c3d4e5f67890?shared=1"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()

    original_video_module = Application.get_env(:tymeslot, :video_module)
    Application.put_env(:tymeslot, :video_module, __MODULE__.NamingVideoModule)

    on_exit(fn ->
      case original_video_module do
        nil -> Application.delete_env(:tymeslot, :video_module)
        mod -> Application.put_env(:tymeslot, :video_module, mod)
      end
    end)

    :ok
  end

  test "a group meeting's participant link is the shared one, and nothing is logged as failing" do
    meeting = build_scenario(:group_meeting)

    log =
      capture_log(fn ->
        assert {:ok, %MeetingSchema{}} = VideoRooms.add_video_room_to_meeting(meeting.id)
      end)

    attached = Repo.get(MeetingSchema, meeting.id)

    assert attached.attendee_video_url == @shared_url
    assert attached.organizer_video_url == @room_url <> "?name=" <> meeting.organizer_name
    refute log =~ "Failed to create secure join URL"
  end

  test "a solo meeting's participant link still names its attendee" do
    meeting = build_scenario(:meeting)

    assert {:ok, %MeetingSchema{}} = VideoRooms.add_video_room_to_meeting(meeting.id)

    attached = Repo.get(MeetingSchema, meeting.id)
    assert attached.attendee_video_url == @room_url <> "?name=" <> meeting.attendee_name
  end

  defp build_scenario(factory) do
    user = insert(:user)
    _profile = insert(:profile, user: user)

    integration =
      insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

    insert(factory,
      organizer_user_id: user.id,
      organizer_email: user.email,
      organizer_name: "Organiser",
      video_integration_id: integration.id,
      video_room_id: nil,
      video_room_enabled: false
    )
  end

  defmodule NamingVideoModule do
    @moduledoc """
    Stands in for `Tymeslot.Integrations.Video` with a provider that puts the
    participant's name in the link and, like Zoom and Teams before the fix,
    raises when there is no name to put there.
    """

    alias Tymeslot.Integrations.Video.MeetingContext
    alias Tymeslot.Integrations.Video.RoomData

    @room_url "https://video.example.com/join/a1b2c3d4e5f67890"

    @spec create_meeting_room(integer() | nil, keyword()) :: {:ok, MeetingContext.t()}
    def create_meeting_room(_user_id, _opts) do
      {:ok,
       %MeetingContext{
         provider_type: :mirotalk,
         room_data: %RoomData{
           room_id: "a1b2c3d4e5f67890",
           meeting_url: @room_url,
           provider_data: %{}
         },
         provider_module: Tymeslot.Integrations.Video.Providers.MiroTalkProvider
       }}
    end

    @spec create_join_url(MeetingContext.t(), String.t(), String.t(), String.t(), DateTime.t()) ::
            {:ok, String.t()}
    def create_join_url(%MeetingContext{room_data: room_data}, name, _email, _role, _time)
        when is_binary(name),
        do: {:ok, room_data.meeting_url <> "?name=" <> name}

    @spec shared_join_url(MeetingContext.t(), DateTime.t() | nil) :: {:ok, String.t()}
    def shared_join_url(%MeetingContext{room_data: room_data}, _time),
      do: {:ok, room_data.meeting_url <> "?shared=1"}

    @spec extract_room_id(map() | String.t()) :: String.t() | nil
    defdelegate extract_room_id(input), to: Tymeslot.Integrations.Video.Urls
  end
end
