defmodule Tymeslot.Integrations.Calendar.BlockingRaceTest do
  @moduledoc """
  A meeting type naming a show-only calendar as its booking calendar while
  that calendar's integration, or the whole account, is deleted, on real
  connections staged by `Tymeslot.Test.RaceConductor` (see its moduledoc for
  why the module is synchronous and why `on_exit` deletes what it
  committed).

  The promotion locks the user's row, then the integration's, then writes
  the meeting type; both deletions take the integration or the user before
  they reach meeting types (see `Calendar.Blocking`). So neither side can
  hold what the other waits for: both finish without a deadlock, and the
  meeting type ends either pointing at a live calendar that blocks, or at
  nothing with the integration gone.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  @moduletag :capture_log

  setup do
    {user, integration, meeting_type} =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user)

        integration =
          insert(:calendar_integration,
            user: user,
            provider: "google",
            default_booking_calendar_id: "work",
            calendar_list: [
              %{id: "work", selected: true, primary: true},
              %{id: "rota", selected: true, blocks_availability: false}
            ]
          )

        {user, integration, insert(:meeting_type, user: user)}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(m in MeetingTypeSchema, where: m.user_id == ^user.id))
        Repo.delete_all(from(p in ProfileSchema, where: p.user_id == ^user.id))
        Repo.delete_all(from(c in CalendarIntegrationSchema, where: c.user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, integration: integration, meeting_type: meeting_type}
  end

  # Parks the meeting-type write at the first lock it takes, so the other
  # side runs while it holds that lock and nothing after it: with the
  # promotion in order that is the user's row; written the other way round it
  # would be the meeting type's row, and the deletion would then deadlock
  # against it.
  defp book_into_rota(hold, ctx) do
    RaceConductor.arm(hold, &first_lock?/1)

    MeetingTypes.update_meeting_type(ctx.meeting_type, %{
      calendar_integration_id: ctx.integration.id,
      target_calendar_id: "rota"
    })
  end

  defp first_lock?(%{source: "users", query: query}), do: query =~ "FOR KEY SHARE"
  defp first_lock?(%{source: "meeting_types", query: query}), do: query =~ "UPDATE"
  defp first_lock?(_metadata), do: false

  defp refute_deadlock(results) do
    for {:raised, error} <- results do
      flunk("a contender raised: #{Exception.message(error)}")
    end
  end

  # Either the meeting type books into a live calendar that blocks, or it
  # names no calendar and the integration is gone.
  defp assert_consistent(ctx) do
    {meeting_type, integration} =
      unboxed(fn ->
        {Repo.get(MeetingTypeSchema, ctx.meeting_type.id),
         Repo.get(CalendarIntegrationSchema, ctx.integration.id)}
      end)

    case {meeting_type, integration} do
      {nil, nil} ->
        :account_gone

      {%{calendar_integration_id: nil, target_calendar_id: nil}, nil} ->
        :integration_gone

      {%{calendar_integration_id: id, target_calendar_id: "rota"}, %{id: id} = live} ->
        assert %{blocks_availability: true} = Enum.find(live.calendar_list, &(&1.id == "rota"))
        :booked_and_blocking

      other ->
        flunk("inconsistent end state: #{inspect(other)}")
    end
  end

  defp delete_integration(ctx),
    do: Deletion.delete_with_primary_reassignment(ctx.user.id, ctx.integration.id)

  # Every outcome but a raise is acceptable to the booking side: it commits,
  # or it is refused because what it named is gone.
  defp booked_or_refused({:ok, %MeetingTypeSchema{}}), do: true
  defp booked_or_refused({:error, %Ecto.Changeset{}}), do: true
  defp booked_or_refused({:error, :not_found}), do: true
  defp booked_or_refused(_other), do: false

  describe "against the integration's deletion" do
    test "when the meeting type takes its first lock first", ctx do
      results =
        race([
          &book_into_rota(&1, ctx),
          fn hold ->
            RaceConductor.arm(hold, RaceConductor.lock_of("calendar_integrations"))
            delete_integration(ctx)
          end
        ])

      refute_deadlock(results)
      assert [booked, {:ok, _deleted}] = results
      assert booked_or_refused(booked)
      assert assert_consistent(ctx) == :integration_gone
    end

    test "when the deletion holds the integration first", ctx do
      # Written the other way round, the meeting type's write would hold its
      # row and wait for the integration while the deletion, holding the
      # integration, waits to clear that row.
      results =
        race([
          &book_into_rota_after_deletion_locks(&1, ctx),
          fn hold ->
            RaceConductor.arm(hold, RaceConductor.lock_of("calendar_integrations"))
            delete_integration(ctx)
          end
        ])

      refute_deadlock(results)
      assert [booked, {:ok, _deleted}] = results
      assert booked_or_refused(booked)
      assert assert_consistent(ctx) == :integration_gone
    end
  end

  describe "against the account's deletion" do
    test "when the meeting type takes its first lock first", ctx do
      results =
        race([
          &book_into_rota(&1, ctx),
          fn hold ->
            RaceConductor.arm(hold, RaceConductor.advisory_lock())
            AccountDeletion.delete_account(ctx.user)
          end
        ])

      refute_deadlock(results)
      assert [booked, {:ok, _deleted}] = results
      assert booked_or_refused(booked)
      assert assert_consistent(ctx) == :account_gone
    end

    test "when the deletion has deleted the user first", ctx do
      results =
        race([
          &book_into_rota_after_deletion_locks(&1, ctx),
          fn hold ->
            RaceConductor.arm(hold, &user_delete?/1)
            AccountDeletion.delete_account(ctx.user)
          end
        ])

      refute_deadlock(results)
      assert [{:error, :not_found}, {:ok, _deleted}] = results
      assert assert_consistent(ctx) == :account_gone
    end
  end

  # Parks before any query, so the deletion runs until it parks holding its
  # locks; both are then released together.
  defp book_into_rota_after_deletion_locks(hold, ctx) do
    {:ok, :released} = hold.(nil)

    MeetingTypes.update_meeting_type(ctx.meeting_type, %{
      calendar_integration_id: ctx.integration.id,
      target_calendar_id: "rota"
    })
  end

  defp user_delete?(%{source: "users", query: query}), do: String.starts_with?(query, "DELETE")
  defp user_delete?(_metadata), do: false
end
