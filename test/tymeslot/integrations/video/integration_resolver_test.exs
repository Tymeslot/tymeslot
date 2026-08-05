defmodule Tymeslot.Integrations.Video.IntegrationResolverTest do
  @moduledoc """
  Tests resolution of the video integration that owns a meeting's provider room,
  including the fallback used after the original integration was disconnected.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :video

  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Integrations.Video.IntegrationResolver

  test "prefers the meeting's own integration link" do
    %{user: user} = create_user_with_profile()
    own = insert(:video_integration, user: user, provider: "zoom")

    meeting =
      build(:meeting,
        organizer_user_id: user.id,
        video_integration_id: own.id,
        video_provider: "zoom"
      )

    assert {:ok, own.id} == IntegrationResolver.resolve_for_meeting(meeting)
  end

  test "falls back to an active integration for the same provider" do
    %{user: user} = create_user_with_profile()
    reconnected = insert(:video_integration, user: user, provider: "zoom", is_active: true)

    meeting =
      build(:meeting,
        organizer_user_id: user.id,
        video_integration_id: nil,
        video_provider: "zoom"
      )

    assert {:ok, reconnected.id} == IntegrationResolver.resolve_for_meeting(meeting)
  end

  test "reports no active integration when the user never reconnected" do
    %{user: user} = create_user_with_profile()

    meeting =
      build(:meeting,
        organizer_user_id: user.id,
        video_integration_id: nil,
        video_provider: "zoom"
      )

    assert {:error, :no_active_integration} = IntegrationResolver.resolve_for_meeting(meeting)
  end

  test "does not borrow an integration belonging to a different provider" do
    %{user: user} = create_user_with_profile()
    insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

    meeting =
      build(:meeting,
        organizer_user_id: user.id,
        video_integration_id: nil,
        video_provider: "zoom"
      )

    assert {:error, :no_active_integration} = IntegrationResolver.resolve_for_meeting(meeting)
  end

  test "does not borrow another user's integration" do
    %{user: owner} = create_user_with_profile()
    %{user: stranger} = create_user_with_profile()
    insert(:video_integration, user: stranger, provider: "zoom", is_active: true)

    meeting =
      build(:meeting,
        organizer_user_id: owner.id,
        video_integration_id: nil,
        video_provider: "zoom"
      )

    assert {:error, :no_active_integration} = IntegrationResolver.resolve_for_meeting(meeting)
  end

  test "ignores an inactive integration when falling back" do
    %{user: user} = create_user_with_profile()
    insert(:video_integration, user: user, provider: "zoom", is_active: false)

    meeting =
      build(:meeting,
        organizer_user_id: user.id,
        video_integration_id: nil,
        video_provider: "zoom"
      )

    assert {:error, :no_active_integration} = IntegrationResolver.resolve_for_meeting(meeting)
  end

  test "reports an unknown provider for rows predating the video_provider column" do
    %{user: user} = create_user_with_profile()
    insert(:video_integration, user: user, provider: "zoom", is_active: true)

    meeting =
      build(:meeting,
        organizer_user_id: user.id,
        video_integration_id: nil,
        video_provider: nil
      )

    assert {:error, :provider_unknown} = IntegrationResolver.resolve_for_meeting(meeting)
  end

  test "reports an unknown provider when the meeting has no organiser" do
    meeting =
      build(:meeting,
        organizer_user_id: nil,
        video_integration_id: nil,
        video_provider: "zoom"
      )

    assert {:error, :provider_unknown} = IntegrationResolver.resolve_for_meeting(meeting)
  end
end
