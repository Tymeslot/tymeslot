defmodule Tymeslot.MeetingTypes.DefaultMeetingTypesBackfillTest do
  @moduledoc """
  Verifies `20261011115211_seed_default_meeting_types_for_profiles_without_any`
  seeds the defaults, as the old lazy seed did, into exactly the profiles that
  have no meeting type, and publishes those that have a username.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types
  @moduletag :database
  @moduletag :migrations

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_011_115_211

  test "seeds profiles without meeting types, publishing those with a username" do
    named = insert(:user)
    insert(:profile, user: named, username: "named-host", booking_page_published_at: nil)

    nameless = insert(:user)
    insert(:profile, user: nameless, username: nil, booking_page_published_at: nil)

    # Already has a type (even an inactive one): left alone.
    kept = insert(:user)
    insert(:profile, user: kept, username: "kept-host", booking_page_published_at: nil)
    insert(:meeting_type, user: kept, name: "Mine", is_active: false)

    # Waiting to be deleted: frozen, so not seeded.
    leaving = insert(:user, deletion_requested_at: DateTime.utc_now(:second))
    insert(:profile, user: leaving, username: "leaving-host")

    MigrationRunner.replay!(@version)

    assert [fifteen, thirty] =
             Enum.sort_by(MeetingTypes.get_all_meeting_types(named.id), & &1.sort_order)

    assert {fifteen.name, fifteen.duration_minutes, fifteen.icon, fifteen.is_active} ==
             {"15 Minutes", 15, "hero-bolt", true}

    assert {thirty.name, thirty.duration_minutes} == {"30 Minutes", 30}

    assert [%LocationOption{kind: "in_person", label: "In person", position: 0, id: id}] =
             fifteen.locations

    assert {:ok, _uuid} = UUID.cast(id)
    assert fifteen.reminder_config == [%{"value" => 30, "unit" => "minutes"}]
    assert %DateTime{} = profile_for(named).booking_page_published_at

    assert length(MeetingTypes.get_all_meeting_types(nameless.id)) == 2
    refute profile_for(nameless).booking_page_published_at

    assert [%{name: "Mine"}] = MeetingTypes.get_all_meeting_types(kept.id)
    refute profile_for(kept).booking_page_published_at

    assert MeetingTypes.get_all_meeting_types(leaving.id) == []
  end

  test "points the defaults at the primary calendar's booking calendar, as the lazy seed did" do
    user = insert(:user)
    profile = insert(:profile, user: user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        default_booking_calendar_id: "work"
      )

    profile
    |> Changeset.change(primary_calendar_integration_id: integration.id)
    |> Repo.update!()

    MigrationRunner.replay!(@version)

    assert [%{calendar_integration_id: id, target_calendar_id: "work"}, _other] =
             MeetingTypes.get_all_meeting_types(user.id)

    assert id == integration.id
  end

  test "running again seeds nothing more" do
    user = insert(:user)
    insert(:profile, user: user)

    MigrationRunner.replay!(@version)
    MigrationRunner.replay!(@version)

    assert length(MeetingTypes.get_all_meeting_types(user.id)) == 2
  end

  defp profile_for(user) do
    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    profile
  end
end
