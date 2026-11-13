defmodule Tymeslot.Onboarding.MeetingConfirmedBackfillTest do
  @moduledoc """
  Drives `20261110175018_backfill_onboarding_meeting_confirmed_at` itself: a host
  mid-onboarding whose meeting type is no longer a seeded default is stamped,
  so the new meeting step gate does not send them back; a host on an untouched
  default of either seed generation, in any language, is not.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :onboarding

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_110_175_018

  @seeded [name: "Intro call", duration_minutes: 30]

  defp mid_onboarding(meeting_type_attrs, user_attrs \\ []) do
    user = insert(:user, Keyword.put_new(user_attrs, :onboarding_completed_at, nil))
    add_meeting_type(user, meeting_type_attrs)
    user
  end

  defp add_meeting_type(user, attrs) do
    insert(
      :meeting_type,
      [user: user, locations: [in_person_location()]]
      |> Keyword.merge(@seeded)
      |> Keyword.merge(attrs)
    )
  end

  defp confirmed_at(user),
    do: Repo.reload!(%UserSchema{id: user.id}).onboarding_meeting_confirmed_at

  test "stamps only the hosts whose meeting type differs from the seeded default" do
    renamed = mid_onboarding(name: "Coaching session")
    longer = mid_onboarding(duration_minutes: 45)
    moved = mid_onboarding(locations: [in_person_location([], kind: :phone, label: "Phone")])
    untouched = mid_onboarding([])
    translated = mid_onboarding(name: "Kennenlerngespräch")
    archived = mid_onboarding(name: "Coaching session", is_active: false)
    no_meeting_type = insert(:user, onboarding_completed_at: nil)

    MigrationRunner.replay!(@version)

    assert %DateTime{} = confirmed_at(renamed)
    assert %DateTime{} = confirmed_at(longer)
    assert %DateTime{} = confirmed_at(moved)
    assert confirmed_at(untouched) == nil
    assert confirmed_at(translated) == nil
    assert confirmed_at(archived) == nil
    assert confirmed_at(no_meeting_type) == nil
  end

  describe "a meeting type whose locations are not the one seeded place" do
    # The column is nullable and was added after rows existed, so a host can
    # hold no list at all or an empty one. Neither is a seeded default.
    defp set_locations(user, value) do
      Repo.query!("UPDATE meeting_types SET locations = #{value} WHERE user_id = $1", [user.id])
    end

    test "a missing or empty list counts as an edited default" do
      missing = mid_onboarding([])
      empty = mid_onboarding([])
      untouched = mid_onboarding([])
      set_locations(missing, "NULL")
      set_locations(empty, "ARRAY[]::jsonb[]")

      MigrationRunner.replay!(@version)

      assert %DateTime{} = confirmed_at(missing)
      assert %DateTime{} = confirmed_at(empty)
      assert confirmed_at(untouched) == nil
    end

    test "a default whose one in-person place is bound to a venue is still the default" do
      # The migration's moduledoc defines a default as a name, a duration and
      # one in-person location; the venues a location lists are not part of it.
      user = insert(:user, onboarding_completed_at: nil)
      venue = insert(:venue, user: user)
      add_meeting_type(user, locations: [in_person_location([venue])])

      MigrationRunner.replay!(@version)

      assert confirmed_at(user) == nil
    end

    test "two places, even both in person, are no longer the seeded default" do
      user = mid_onboarding(locations: [in_person_location(), in_person_location()])

      MigrationRunner.replay!(@version)

      assert %DateTime{} = confirmed_at(user)
    end
  end

  describe "the earlier pair of seeded defaults" do
    test "a host still on both is not stamped" do
      user = mid_onboarding(name: "15 Minutes", duration_minutes: 15)
      add_meeting_type(user, name: "30 Minutes", duration_minutes: 30)

      MigrationRunner.replay!(@version)

      assert confirmed_at(user) == nil
    end

    test "a host who edited one of them is stamped" do
      renamed = mid_onboarding(name: "Discovery", duration_minutes: 15)
      add_meeting_type(renamed, name: "30 Minutes", duration_minutes: 30)

      # The name of one default with the length of the other was never seeded.
      lengthened = mid_onboarding(name: "15 Minutes", duration_minutes: 30)

      moved =
        mid_onboarding(
          name: "30 Minutes",
          duration_minutes: 30,
          locations: [in_person_location([], kind: :phone, label: "Phone")]
        )

      MigrationRunner.replay!(@version)

      assert %DateTime{} = confirmed_at(renamed)
      assert %DateTime{} = confirmed_at(lengthened)
      assert %DateTime{} = confirmed_at(moved)
    end
  end

  test "leaves completed accounts to be counted as confirmed at read time" do
    user =
      mid_onboarding([name: "Coaching session"],
        onboarding_completed_at: ~U[2026-01-01 09:00:00Z]
      )

    MigrationRunner.replay!(@version)

    assert confirmed_at(user) == nil
  end

  test "keeps the time of a host who has already confirmed the step" do
    first = ~U[2026-01-01 09:00:00Z]
    user = mid_onboarding([name: "Coaching session"], onboarding_meeting_confirmed_at: first)

    MigrationRunner.replay!(@version)

    assert confirmed_at(user) == first
  end
end
