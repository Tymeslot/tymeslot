defmodule Tymeslot.MeetingTypes.LocationSelectionTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.LocationSelection

  defp option(attrs), do: struct!(%LocationOption{}, attrs)

  defp office, do: option(id: "loc-office", kind: "in_person", label: "The office", position: 0)

  defp zoom,
    do:
      option(
        id: "loc-zoom",
        kind: "video",
        label: "Zoom",
        video_integration_ids: [7],
        position: 1
      )

  defp teams,
    do:
      option(
        id: "loc-teams",
        kind: "video",
        label: "Teams",
        video_integration_ids: [9],
        position: 2
      )

  defp video_call,
    do:
      option(
        id: "loc-video",
        kind: "video",
        label: "Video call",
        video_integration_ids: [7, 9],
        position: 1
      )

  defp call_me,
    do:
      option(
        id: "loc-call",
        kind: "phone",
        label: "Phone call",
        collect_from_guest: true,
        position: 3
      )

  describe "options/1" do
    test "returns the host's list in their own order, not storage order" do
      type = %{locations: [teams(), office(), zoom()]}

      assert ["The office", "Zoom", "Teams"] =
               type |> LocationSelection.options() |> Enum.map(& &1.label)
    end

    test "a meeting type with no list falls back to the video call it already offered" do
      type = %{locations: [], allow_video: true, video_integration_id: 42}

      assert [%LocationOption{kind: "video", video_integration_ids: [42]}] =
               LocationSelection.options(type)
    end

    test "a meeting type with no list and no video falls back to one in-person location" do
      type = %{locations: [], allow_video: false, video_integration_id: nil}

      assert [%LocationOption{kind: "in_person"}] = LocationSelection.options(type)
    end

    test "the fallback ids are stable, so a submitted id still resolves" do
      type = %{locations: [], allow_video: false, video_integration_id: nil}

      assert [%{id: first}] = LocationSelection.options(type)
      assert [%{id: ^first}] = LocationSelection.options(type)
    end

    test "an ad-hoc booking with no meeting type has no locations at all" do
      assert LocationSelection.options(nil) == []
    end
  end

  describe "choice_required?/1" do
    test "is false for a single location, which is stated rather than chosen" do
      refute LocationSelection.choice_required?(%{locations: [office()]})
    end

    test "is true once there is more than one" do
      assert LocationSelection.choice_required?(%{locations: [office(), zoom()]})
    end

    test "is false for a meeting type falling back to its derived single location" do
      refute LocationSelection.choice_required?(%{
               locations: [],
               allow_video: true,
               video_integration_id: 42
             })
    end
  end

  describe "resolve/3" do
    test "resolves the chosen option into the meeting's location fields" do
      type = %{locations: [office(), zoom()]}

      assert %{
               location: "The office",
               location_kind: "in_person",
               location_option_id: "loc-office",
               video_integration_id: nil,
               attendee_phone: nil
             } = LocationSelection.resolve(type, "loc-office")
    end

    test "a video location carries the integration its room will be created on" do
      type = %{locations: [office(), zoom(), teams()]}

      assert %{location_kind: "video", video_integration_id: 9, location: "Teams"} =
               LocationSelection.resolve(type, "loc-teams")
    end

    test "an unknown id resolves to the first option rather than being honoured" do
      type = %{locations: [office(), zoom()]}

      assert %{location_option_id: "loc-office", video_integration_id: nil} =
               LocationSelection.resolve(type, "loc-forged")
    end

    test "no id at all resolves to the first option" do
      type = %{locations: [office(), zoom()]}

      assert %{location_option_id: "loc-office"} = LocationSelection.resolve(type, nil)
    end

    test "folds the booker's own number into a location that asked for one" do
      type = %{locations: [office(), call_me()]}

      assert %{
               location: "Phone call (+44 7700 900123)",
               location_kind: "phone",
               attendee_phone: "+44 7700 900123"
             } = LocationSelection.resolve(type, "loc-call", "  +44 7700 900123  ")
    end

    test "a phone location left blank by the booker still names itself" do
      type = %{locations: [office(), call_me()]}

      assert %{location: "Phone call", attendee_phone: nil} =
               LocationSelection.resolve(type, "loc-call", "   ")
    end

    test "ignores a number submitted against a location that never asked for one" do
      type = %{locations: [office(), zoom()]}

      assert %{location: "Zoom", attendee_phone: nil} =
               LocationSelection.resolve(type, "loc-zoom", "+44 7700 900123")
    end

    test "a video location offering several providers lands on the one the booker picked" do
      type = %{locations: [office(), video_call()]}

      assert %{video_integration_id: 9} = LocationSelection.resolve(type, "loc-video", nil, "9")
    end

    test "with no provider picked, a video location lands on its first" do
      type = %{locations: [office(), video_call()]}

      assert %{video_integration_id: 7} = LocationSelection.resolve(type, "loc-video")
    end

    test "a provider the location does not list is not honoured" do
      type = %{locations: [office(), video_call()]}

      assert %{video_integration_id: 7} = LocationSelection.resolve(type, "loc-video", nil, 99)
    end

    test "a provider submitted against a location that is not a video call is ignored" do
      type = %{locations: [office(), video_call()]}

      assert %{video_integration_id: nil} =
               LocationSelection.resolve(type, "loc-office", nil, 9)
    end

    test "an ad-hoc booking resolves to no location at all" do
      assert %{
               location: nil,
               location_kind: nil,
               location_option_id: nil,
               video_integration_id: nil,
               attendee_phone: nil
             } = LocationSelection.resolve(nil, nil)
    end
  end
end
