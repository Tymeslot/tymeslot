defmodule Tymeslot.Meetings.VideoRoomsJoinUrlFallbackTest do
  @moduledoc """
  Regression test for the join-URL fallback in
  `Tymeslot.Meetings.VideoRooms.add_video_room_to_meeting/1`.

  Every provider's `create_join_url/5` can fail. When it does, the room's own
  URL is the link the participants get. Before this fallback existed, the
  failure produced a relative string built from the room id
  (`"a1b2c3?name=Ada"`), which was persisted as `organizer_video_url` and
  `attendee_video_url` and mailed out in the confirmation, so the participant
  received a link that opened nothing.
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

  @room_url "https://video.example.com/join/a1b2c3d4e5f67890"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()

    original_video_module = Application.get_env(:tymeslot, :video_module)
    Application.put_env(:tymeslot, :video_module, __MODULE__.FailingJoinUrlVideoModule)

    on_exit(fn ->
      Application.delete_env(:tymeslot, :test_video_room_meeting_url)

      case original_video_module do
        nil -> Application.delete_env(:tymeslot, :video_module)
        mod -> Application.put_env(:tymeslot, :video_module, mod)
      end
    end)

    :ok
  end

  describe "add_video_room_to_meeting/1 when the provider cannot mint a join URL" do
    test "falls back to the room's own URL for both participants" do
      Application.put_env(:tymeslot, :test_video_room_meeting_url, @room_url)
      meeting = build_mirotalk_scenario()

      assert {:ok, %MeetingSchema{}} = VideoRooms.add_video_room_to_meeting(meeting.id)

      attached = Repo.get(MeetingSchema, meeting.id)
      assert attached.video_room_enabled

      # `@room_url` is absolute, so equality is also the assertion that neither
      # participant was handed a relative link.
      assert attached.organizer_video_url == @room_url
      assert attached.attendee_video_url == @room_url

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => meeting.id}
      )
    end

    test "refuses the room when its URL is a bare room id rather than a link" do
      Application.put_env(:tymeslot, :test_video_room_meeting_url, "a1b2c3d4e5f67890")
      meeting = build_mirotalk_scenario()

      assert {:error, :join_url_unavailable} = VideoRooms.add_video_room_to_meeting(meeting.id)

      assert_meeting_untouched(meeting.id)
    end

    test "refuses the room when it carries no URL at all" do
      Application.put_env(:tymeslot, :test_video_room_meeting_url, nil)
      meeting = build_mirotalk_scenario()

      assert {:error, :join_url_unavailable} = VideoRooms.add_video_room_to_meeting(meeting.id)

      assert_meeting_untouched(meeting.id)
    end
  end

  defp assert_meeting_untouched(meeting_id) do
    unchanged = Repo.get(MeetingSchema, meeting_id)

    refute unchanged.video_room_enabled
    assert is_nil(unchanged.video_room_id)
    assert is_nil(unchanged.organizer_video_url)
    assert is_nil(unchanged.attendee_video_url)

    refute_enqueued(worker: CalendarEventWorker)
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

  defmodule FailingJoinUrlVideoModule do
    @moduledoc """
    Stands in for `Tymeslot.Integrations.Video`, returning a usable room whose
    join URLs the provider then refuses to mint. The room's own URL is read
    from `:test_video_room_meeting_url` so each test picks the shape it needs.
    """

    alias Tymeslot.Integrations.Video.MeetingContext
    alias Tymeslot.Integrations.Video.RoomData

    @spec create_meeting_room(integer() | nil, keyword()) :: {:ok, MeetingContext.t()}
    def create_meeting_room(_user_id, _opts) do
      {:ok,
       %MeetingContext{
         provider_type: :mirotalk,
         room_data: %RoomData{
           room_id: "a1b2c3d4e5f67890",
           meeting_url: Application.get_env(:tymeslot, :test_video_room_meeting_url),
           provider_data: %{}
         },
         provider_module: Tymeslot.Integrations.Video.Providers.MiroTalkProvider
       }}
    end

    @spec create_join_url(map(), String.t(), String.t(), String.t(), DateTime.t()) ::
            {:error, :invalid_parameters}
    def create_join_url(_ctx, _name, _email, _role, _start_time),
      do: {:error, :invalid_parameters}

    @spec extract_room_id(map() | String.t()) :: String.t() | nil
    defdelegate extract_room_id(input), to: Tymeslot.Integrations.Video.Urls
  end
end
