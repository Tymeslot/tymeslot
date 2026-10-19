defmodule Tymeslot.Integrations.Calendar.PrimaryElectionRaceTest do
  @moduledoc """
  A calendar created while the primary is being deleted, on real connections
  staged by `Tymeslot.Test.RaceConductor` (see its moduledoc for why the
  module is synchronous and why `on_exit` deletes what it committed).

  Each side parks once it has decided: the create after reading the stored
  primary's row, the delete as it writes the profile. Both take the primary
  lock first, so whichever holds it decides and commits before the other
  reads anything, and the new calendar ends up the primary either way.
  Without one shared lock both decide at once: the create sees the old
  primary still standing, the delete elects from a list without the
  uncommitted new row, and the user is left with no primary at all.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    {user, primary} =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user)
        primary = insert(:calendar_integration, user: user, provider: "caldav")
        {:ok, _profile} = ProfileQueries.set_primary_calendar_integration(user.id, primary.id)
        {user, primary}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(p in ProfileSchema, where: p.user_id == ^user.id))
        Repo.delete_all(from(c in CalendarIntegrationSchema, where: c.user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, primary: primary}
  end

  test "a calendar created while the primary is deleted becomes the primary", ctx do
    [created, deleted] =
      race([
        fn hold ->
          RaceConductor.arm(hold, &plain_read_of_integrations?/1)
          Management.insert_integration(attrs(ctx.user))
        end,
        fn hold ->
          RaceConductor.arm(hold, &profile_write?/1)
          Deletion.delete_with_primary_reassignment(ctx.user.id, ctx.primary.id)
        end
      ])

    assert {:ok, %CalendarIntegrationSchema{id: new_id}} = created
    assert {:ok, _deleted} = deleted

    assert unboxed(fn ->
             {:ok, profile} = ProfileQueries.get_by_user_id(ctx.user.id)
             profile.primary_calendar_integration_id
           end) == new_id
  end

  test "two deletes of the same calendar: one deletes it, the other finds it gone", ctx do
    results =
      race([
        fn hold ->
          RaceConductor.arm(hold, RaceConductor.lock_of("calendar_integrations"))
          Deletion.delete_with_primary_reassignment(ctx.user.id, ctx.primary.id)
        end,
        fn hold ->
          RaceConductor.arm(hold, RaceConductor.lock_of("calendar_integrations"))
          Deletion.delete_with_primary_reassignment(ctx.user.id, ctx.primary.id)
        end
      ])

    assert Enum.count(results, &match?({:ok, _deleted}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_found})) == 1
  end

  defp plain_read_of_integrations?(meta) do
    meta[:source] == "calendar_integrations" and String.starts_with?(meta[:query], "SELECT") and
      not (meta[:query] =~ "FOR UPDATE")
  end

  defp profile_write?(meta),
    do: meta[:source] == "profiles" and String.starts_with?(meta[:query], "UPDATE")

  defp attrs(user) do
    %{
      user_id: user.id,
      name: "Created during the delete",
      provider: "caldav",
      base_url: "https://dav.example.com",
      username: "racer",
      password: "secret",
      provider_account_id: "https://dav.example.com||racer",
      calendar_paths: ["/dav/racer"],
      is_active: true
    }
  end
end
