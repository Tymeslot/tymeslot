defmodule Tymeslot.Integrations.Calendar.RemovedCalendarsRaceTest do
  @moduledoc """
  Two reads deselecting different missing calendars of one integration at
  once, on real connections staged by `Tymeslot.Test.RaceConductor` (see its
  moduledoc for why the module is synchronous and why `on_exit` deletes what
  it committed).

  Each deselection rewrites the whole selection and the whole list of
  removed calendars, so it must start from the row the other one left: with
  the row lock, the second waits for the first to commit and keeps both
  calendars; without it, the later write would drop the earlier one's.
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
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  @moduletag :capture_log

  setup do
    integration =
      unboxed(fn ->
        insert(:calendar_integration,
          provider: "google",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{id: "primary", selected: true, name: "Primary"},
            %{id: "work", selected: true, name: "Work"},
            %{id: "team", selected: true, name: "Team"}
          ]
        )
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(j in Oban.Job,
            where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id))
          )
        )

        Repo.delete_all(from(c in CalendarIntegrationSchema, where: c.id == ^integration.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^integration.user_id))
      end)
    end)

    RaceConductor.attach_parking()

    %{integration: integration}
  end

  # Parks once the row lock is taken, so the other deselection runs as far
  # as it can while this one holds it.
  defp deselect(hold, integration, calendar_id) do
    RaceConductor.arm(hold, RaceConductor.lock_of("calendar_integrations"))
    Selection.deselect_missing(integration, [calendar_id])
  end

  test "both calendars are deselected and recorded, and each is emailed about", %{
    integration: integration
  } do
    assert [{:ok, _work}, {:ok, _team}] =
             race([
               &deselect(&1, integration, "work"),
               &deselect(&1, integration, "team")
             ])

    {row, emailed} =
      unboxed(fn ->
        jobs =
          Repo.all(
            from(j in Oban.Job,
              where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id))
            )
          )

        {Repo.get!(CalendarIntegrationSchema, integration.id),
         jobs |> Enum.flat_map(& &1.args["calendar_names"]) |> Enum.sort()}
      end)

    assert row.calendar_list |> Enum.filter(& &1.selected) |> Enum.map(& &1.id) == ["primary"]
    assert row.removed_calendars |> Enum.map(& &1.id) |> Enum.sort() == ["team", "work"]
    assert emailed == ["Team", "Work"]
  end
end
