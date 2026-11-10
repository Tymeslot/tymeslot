defmodule Tymeslot.Onboarding.MeetingConfirmedBackfillTest do
  @moduledoc """
  Drives `20261110165152_add_onboarding_meeting_confirmed_at_to_users` itself:
  a host mid-onboarding whose meeting type is no longer the seeded default is
  stamped, so the new meeting step gate does not send them back; a host on the
  untouched default, in any language, is not.

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

  @version 20_261_110_165_152

  @seeded [name: "Intro call", duration_minutes: 30]

  defp mid_onboarding(meeting_type_attrs) do
    user = insert(:user, onboarding_completed_at: nil)

    insert(
      :meeting_type,
      [user: user, locations: [in_person_location()]]
      |> Keyword.merge(@seeded)
      |> Keyword.merge(meeting_type_attrs)
    )

    user
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

    MigrationRunner.rerun!(@version)

    assert %DateTime{} = confirmed_at(renamed)
    assert %DateTime{} = confirmed_at(longer)
    assert %DateTime{} = confirmed_at(moved)
    assert confirmed_at(untouched) == nil
    assert confirmed_at(translated) == nil
    assert confirmed_at(archived) == nil
    assert confirmed_at(no_meeting_type) == nil
  end

  test "leaves completed accounts to be counted as confirmed at read time" do
    user = insert(:user, onboarding_completed_at: ~U[2026-01-01 09:00:00Z])
    insert(:meeting_type, user: user, name: "Coaching session", locations: [in_person_location()])

    MigrationRunner.rerun!(@version)

    assert confirmed_at(user) == nil
  end
end
