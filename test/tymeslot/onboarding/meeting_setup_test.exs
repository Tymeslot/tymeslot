defmodule Tymeslot.Onboarding.MeetingSetupTest do
  @moduledoc """
  The meeting a first-run host sets up: which meeting type the wizard
  edits, and the ownership checks its saves keep.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :onboarding

  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Onboarding.MeetingSetup

  describe "meeting_type/1" do
    test "a host with no meeting type gets the default seeded" do
      user = insert(:user)

      assert {:ok, %{name: "Intro call", duration_minutes: 30, is_active: true} = seeded} =
               MeetingSetup.meeting_type(user.id)

      assert [%{id: id}] = MeetingTypes.get_all_meeting_types(user.id)
      assert id == seeded.id
    end

    test "a host whose types are all archived gets a fresh default, not an archived one back" do
      user = insert(:user)
      archived = insert(:meeting_type, user: user, name: "Intro call", is_active: false)

      assert {:ok, %{id: id, name: "Intro call 2", is_active: true}} =
               MeetingSetup.meeting_type(user.id)

      refute id == archived.id
      assert %{is_active: false} = MeetingTypes.get_meeting_type(archived.id, user.id)
    end

    test "a host with an active type keeps editing it" do
      user = insert(:user)
      type = insert(:meeting_type, user: user, is_active: true)

      assert {:ok, %{id: id}} = MeetingSetup.meeting_type(user.id)
      assert id == type.id
      assert length(MeetingTypes.get_all_meeting_types(user.id)) == 1
    end
  end

  describe "saving" do
    setup do
      user = insert(:user)
      {:ok, meeting_type} = MeetingSetup.meeting_type(user.id)
      %{user: user, meeting_type: meeting_type}
    end

    test "a video location naming another host's integration is refused", %{
      meeting_type: meeting_type
    } do
      foreign = insert(:video_integration, user: insert(:user), is_active: true)

      assert {:error, :invalid_video_integration} =
               MeetingTypes.update_meeting_type_checked(meeting_type, %{
                 locations: [
                   %{kind: :video, label: "Video call", video_integration_ids: [foreign.id]}
                 ]
               })

      assert %{locations: [%{kind: :in_person}]} =
               MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)
    end

    test "an invalid name or length is refused with each field's error", %{
      meeting_type: meeting_type
    } do
      assert {:error, %{name: :required, duration_minutes: :invalid}} =
               MeetingSetup.save(meeting_type, %{
                 name: " \u0000 ",
                 duration_minutes: 52,
                 location: nil
               })
    end

    test "a save keeps the cached calendar events", %{user: user, meeting_type: meeting_type} do
      AvailabilityCache.clear_all()
      key = AvailabilityCache.booking_window_events_key(user.id)
      {:ok, [:cached]} = AvailabilityCache.get_or_compute_events(key, fn -> {:ok, [:cached]} end)

      assert {:ok, %{duration_minutes: 45}} =
               MeetingSetup.save(meeting_type, %{
                 name: "Consultation",
                 duration_minutes: 45,
                 location: :phone
               })

      assert {:ok, [:cached]} =
               AvailabilityCache.get_or_compute_events(key, fn -> {:ok, [:fresh]} end)
    end
  end
end
