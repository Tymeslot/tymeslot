defmodule Tymeslot.Meetings.VideoRoomsTransactionTest do
  @moduledoc """
  Regression test for the "HTTP call outside of DB transaction" contract of
  `Tymeslot.Meetings.VideoRooms.add_video_room_to_meeting/1`.

  The video provider is reached over HTTP. If the call is made inside a
  `Repo.transaction`, the Ecto pool holds a database connection for the duration
  of the remote request, which exhausts the pool when the provider is slow.

  This test uses a local fake video module, wired in via the
  `:tymeslot, :video_module` config key, to assert that `Repo.in_transaction?/0`
  is `false` at the instant `create_meeting_room/2` is invoked.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    # Ensure all external dependencies (email, calendar, subscription, HTTP fallback)
    # have sensible stubs so the code under test can progress to the provider call.
    TestMocks.setup_all_mocks()

    original_video_module = Application.get_env(:tymeslot, :video_module)
    Application.put_env(:tymeslot, :video_module, __MODULE__.FakeVideoModule)

    # Clean slate for every test so earlier recordings don't leak in.
    __MODULE__.FakeVideoModule.reset()

    on_exit(fn ->
      case original_video_module do
        nil -> Application.delete_env(:tymeslot, :video_module)
        mod -> Application.put_env(:tymeslot, :video_module, mod)
      end
    end)

    :ok
  end

  describe "add_video_room_to_meeting/1 transaction boundaries" do
    test "invokes the video provider outside of any DB transaction" do
      %{meeting: meeting} = build_mirotalk_scenario()

      assert {:ok, %MeetingSchema{} = updated} =
               VideoRooms.add_video_room_to_meeting(meeting.id)

      # The fake recorded whether it was called inside a transaction.
      assert __MODULE__.FakeVideoModule.called?(),
             "expected video provider to be invoked"

      refute __MODULE__.FakeVideoModule.called_in_transaction?(),
             "video provider must be called outside any Repo.transaction"

      assert updated.video_room_id == "https://fake.video/join/abc"
      assert updated.video_room_enabled

      assert_enqueued(
        worker: Tymeslot.Workers.CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => meeting.id}
      )
    end

    test "is idempotent when the meeting already has a video room attached" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      integration =
        insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: integration.id,
          video_room_id: "pre-existing-room",
          video_room_enabled: true
        )

      assert {:ok, returned} = VideoRooms.add_video_room_to_meeting(meeting.id)
      assert returned.id == meeting.id
      assert returned.video_room_id == "pre-existing-room"

      refute __MODULE__.FakeVideoModule.called?(),
             "provider must not be contacted when the room is already attached"

      refute_enqueued(worker: Tymeslot.Workers.CalendarEventWorker)
    end

    test "is idempotent when a concurrent writer attaches the room between the HTTP call and the write" do
      %{meeting: meeting} = build_mirotalk_scenario()

      # Simulate a racing worker that attaches a room after the HTTP call returns
      # but before the locking transaction reads the row. The fake module performs
      # this update synchronously as a side effect of the HTTP-equivalent call.
      __MODULE__.FakeVideoModule.attach_before_return(meeting.id, "racer-room-id")

      assert {:ok, returned} = VideoRooms.add_video_room_to_meeting(meeting.id)

      # The pre-existing room wins — we do not overwrite the racer's attachment.
      assert returned.id == meeting.id
      assert returned.video_room_id == "racer-room-id"

      assert __MODULE__.FakeVideoModule.called?()

      refute __MODULE__.FakeVideoModule.called_in_transaction?(),
             "video provider must be called outside any Repo.transaction even on race"

      refute_enqueued(worker: Tymeslot.Workers.CalendarEventWorker)
    end
  end

  defp build_mirotalk_scenario do
    user = insert(:user)
    _profile = insert(:profile, user: user)

    integration =
      insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        video_integration_id: integration.id
      )

    %{user: user, integration: integration, meeting: meeting}
  end

  defmodule FakeVideoModule do
    @moduledoc false

    alias Tymeslot.Meetings.MeetingQueries
    alias Tymeslot.Repo

    @table __MODULE__

    @spec reset() :: :ok
    def reset do
      ensure_table()
      :ets.delete_all_objects(@table)
      :ok
    end

    @spec called?() :: boolean()
    def called? do
      ensure_table()
      :ets.member(@table, :in_transaction)
    end

    @spec called_in_transaction?() :: boolean()
    def called_in_transaction? do
      ensure_table()

      case :ets.lookup(@table, :in_transaction) do
        [{:in_transaction, value}] -> value
        [] -> false
      end
    end

    @doc """
    Instructs the fake to update the meeting row with `room_id` before returning
    its `{:ok, context}` response. This simulates a concurrent writer attaching
    a room between the HTTP response and the locking write.
    """
    @spec attach_before_return(String.t(), String.t()) :: :ok
    def attach_before_return(meeting_id, room_id) do
      ensure_table()
      :ets.insert(@table, {:race_attach, {meeting_id, room_id}})
      :ok
    end

    @spec create_meeting_room(integer() | nil, keyword()) :: {:ok, MeetingContext.t()}
    def create_meeting_room(_user_id, opts) do
      ensure_table()
      :ets.insert(@table, {:in_transaction, Repo.in_transaction?()})

      maybe_simulate_race(opts)

      {:ok,
       %MeetingContext{
         provider_type: :mirotalk,
         room_data: %RoomData{
           meeting_url: "https://fake.video/join/abc",
           room_id: "https://fake.video/join/abc",
           provider_data: %{}
         },
         provider_module: __MODULE__
       }}
    end

    @spec create_join_url(MeetingContext.t(), String.t(), String.t(), String.t(), DateTime.t()) ::
            {:ok, String.t()}
    def create_join_url(_ctx, _name, _email, role, _start_time) do
      {:ok, "https://fake.video/join/abc?role=#{role}"}
    end

    @spec extract_room_id(MeetingContext.t() | String.t()) :: String.t() | nil
    def extract_room_id(%{room_data: %{meeting_url: url}}), do: url
    def extract_room_id(%{room_data: %{room_id: id}}), do: id
    def extract_room_id(url) when is_binary(url), do: url
    def extract_room_id(_other), do: nil

    defp maybe_simulate_race(opts) do
      ensure_table()

      case :ets.lookup(@table, :race_attach) do
        [{:race_attach, {meeting_id, room_id}}] ->
          if to_string(Keyword.get(opts, :meeting_id)) == meeting_id do
            {:ok, meeting} = MeetingQueries.get_meeting(meeting_id)

            {:ok, _updated} =
              MeetingQueries.update_meeting(meeting, %{
                video_room_id: room_id,
                video_room_enabled: true
              })
          end

        [] ->
          :ok
      end
    end

    defp ensure_table do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:set, :public, :named_table])
        _ref -> :ok
      end
    end
  end
end
