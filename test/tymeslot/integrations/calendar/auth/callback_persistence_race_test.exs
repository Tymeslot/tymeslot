defmodule Tymeslot.Integrations.Calendar.CallbackPersistenceRaceTest do
  @moduledoc """
  Two callbacks for the same provider account racing to connect it, on real
  connections staged by `Tymeslot.Test.RaceConductor` (see its moduledoc for
  why the module is synchronous and why `on_exit` deletes what it committed).

  Each callback parks once it has looked the account up and found nothing,
  so both go on to insert. One insert wins; the other hits the account's
  unique index and must reconnect the row that won, as any reconnect does.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CallbackPersistence
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup :set_mox_global

  setup do
    user =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user)
        user
      end)

    on_exit(fn ->
      unboxed(fn ->
        integration_ids =
          Repo.all(
            from(c in CalendarIntegrationSchema, where: c.user_id == ^user.id, select: c.id)
          )

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              j.worker == ^inspect(IntegrationHealthWorker) and
                fragment("(?->>'integration_id')::bigint", j.args) in ^integration_ids
          )
        )

        Repo.delete_all(
          from(h in IntegrationHealthStateSchema,
            where: h.integration_type == "calendar" and h.integration_id in ^integration_ids
          )
        )

        Repo.delete_all(from(p in ProfileSchema, where: p.user_id == ^user.id))
        Repo.delete_all(from(c in CalendarIntegrationSchema, where: c.user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    # The winner discovers its calendars after inserting; the loser may too,
    # if it reads the winner's row before that discovery lands.
    stub(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
      {:ok, [%{"id" => "cal1", "summary" => "Primary"}]}
    end)

    %{user: user}
  end

  test "the callback that loses the insert reconnects the row that won", %{user: user} do
    report_refused_inserts()

    contender = fn token ->
      fn hold ->
        Process.put(:race_token, token)
        RaceConductor.arm(hold, &reactivation_lookup?/1, must_park: true)
        CallbackPersistence.upsert("google", user.id, nil, tokens(token))
      end
    end

    results = race([contender.("first-access"), contender.("second-access")])

    assert [{:ok, %{id: id}}, {:ok, %{id: id}}] = results

    {stored, jobs} =
      unboxed(fn ->
        {Repo.all(from(c in CalendarIntegrationSchema, where: c.user_id == ^user.id)),
         Repo.all(
           from(j in Oban.Job,
             where:
               j.worker == ^inspect(IntegrationHealthWorker) and
                 fragment("(?->>'integration_id')::bigint", j.args) == ^id
           )
         )}
      end)

    assert [%{id: ^id} = row] = stored

    # Exactly one insert was refused, and its callback's tokens are the ones
    # stored: its reconnect wrote them over the winner's and, as a fresh
    # grant, asked for an immediate health probe.
    assert_received {:insert_refused, loser_token}
    refute_received {:insert_refused, _token}
    assert CalendarIntegrationSchema.decrypt_oauth_tokens(row).access_token == loser_token

    assert [%{args: %{"type" => "calendar", "integration_id" => ^id}}] = jobs
  end

  # Tells the test which contender's insert the unique index refused.
  defp report_refused_inserts do
    test_pid = self()
    handler_id = "refused-insert-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if RaceConductor.insert_into("calendar_integrations").(meta) and
               match?({:error, _reason}, meta[:result]) do
            send(test_pid, {:insert_refused, Process.get(:race_token)})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # The lookup for any row of the account, active or not, which is the last
  # read before the insert; it is the only one ordered by `is_active`.
  defp reactivation_lookup?(meta) do
    meta[:source] == "calendar_integrations" and String.starts_with?(meta[:query], "SELECT") and
      meta[:query] =~ "ORDER BY"
  end

  defp tokens(access_token) do
    %{
      access_token: access_token,
      refresh_token: "race-refresh",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600, :second),
      scope: "calendar",
      provider_account_id: "sub-race",
      provider_account_email: "race@example.com"
    }
  end
end
