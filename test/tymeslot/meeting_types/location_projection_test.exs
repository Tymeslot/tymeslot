defmodule Tymeslot.MeetingTypes.LocationProjectionTest do
  @moduledoc """
  `allow_video` and `video_integration_id` are no longer authored: the
  changeset derives them from the location list so the many readers that only
  ask "does this type do video, and on which integration" keep working.

  These lock in that the projection is applied whenever the list is cast, and
  — just as importantly — that it is *not* applied when the list is absent,
  which is what stops a rename or an active-toggle from silently blanking a
  meeting type's video configuration.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types
  @moduletag :schema

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  defp location(attrs), do: Enum.into(attrs, %{})

  defp changeset(meeting_type, attrs),
    do: MeetingTypeSchema.changeset(meeting_type, attrs)

  defp base_attrs(extra) do
    Map.merge(%{name: "Strategy Call", duration_minutes: 30, user_id: 1}, extra)
  end

  describe "projecting the video fields from the location list" do
    test "a video location sets allow_video and the integration it names" do
      cs =
        changeset(
          %MeetingTypeSchema{},
          base_attrs(%{
            locations: [location(kind: "video", label: "Zoom", video_integration_id: 7)]
          })
        )

      assert Changeset.get_field(cs, :allow_video) == true
      assert Changeset.get_field(cs, :video_integration_id) == 7
    end

    test "the first video location wins when several are offered" do
      cs =
        changeset(
          %MeetingTypeSchema{},
          base_attrs(%{
            locations: [
              location(kind: "in_person", label: "The office", position: 0),
              location(kind: "video", label: "Zoom", video_integration_id: 7, position: 1),
              location(kind: "video", label: "Teams", video_integration_id: 9, position: 2)
            ]
          })
        )

      assert Changeset.get_field(cs, :video_integration_id) == 7
    end

    test "a list with no video location clears both fields" do
      existing = %MeetingTypeSchema{allow_video: true, video_integration_id: 7}

      cs =
        changeset(
          existing,
          base_attrs(%{locations: [location(kind: "in_person", label: "The office")]})
        )

      assert Changeset.get_field(cs, :allow_video) == false
      assert Changeset.get_field(cs, :video_integration_id) == nil
    end

    test "a changeset that never touches the list leaves the pair alone" do
      existing = %MeetingTypeSchema{allow_video: true, video_integration_id: 7}

      cs = changeset(existing, base_attrs(%{name: "Renamed"}))

      assert Changeset.get_field(cs, :allow_video) == true
      assert Changeset.get_field(cs, :video_integration_id) == 7
    end
  end

  describe "requiring somewhere to be held" do
    test "rejects an explicitly empty list" do
      cs = changeset(%MeetingTypeSchema{}, base_attrs(%{locations: []}))

      refute cs.valid?
      assert %{locations: ["must include at least one location"]} = errors_on(cs)
    end

    test "accepts a changeset that simply does not mention locations" do
      assert changeset(%MeetingTypeSchema{}, base_attrs(%{})).valid?
    end
  end

  describe "round-tripping through the database" do
    test "the list and its projection survive an insert" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      {:ok, meeting_type} =
        %MeetingTypeSchema{}
        |> changeset(
          base_attrs(%{
            user_id: user.id,
            locations: [
              location(
                kind: "in_person",
                label: "The office",
                details: "12 High St",
                position: 0
              ),
              location(
                kind: "video",
                label: "Zoom",
                video_integration_id: integration.id,
                position: 1
              )
            ]
          })
        )
        |> Repo.insert()

      reloaded = Repo.get!(MeetingTypeSchema, meeting_type.id)

      assert [in_person, video] = reloaded.locations
      assert in_person.kind == "in_person"
      assert in_person.details == "12 High St"
      assert video.video_integration_id == integration.id
      assert reloaded.allow_video == true
      assert reloaded.video_integration_id == integration.id
    end
  end
end
