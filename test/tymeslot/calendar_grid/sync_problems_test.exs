defmodule Tymeslot.CalendarGrid.SyncProblemsTest do
  @moduledoc "Which accounts the calendar's sync banner names, and why."

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.SyncProblems

  @work %{id: 1, name: "Work account", needs_reauth: false}
  @home %{id: 2, name: "Home", needs_reauth: false}

  defp pending(integration_id, summary),
    do: %{
      id: 9,
      calendar_integration_id: integration_id,
      summary: summary,
      sync_state: "locally_modified"
    }

  test "an account whose sync keeps failing is unreachable, with the changes waiting on it" do
    events = [
      pending(1, "Dentist"),
      %{id: 8, calendar_integration_id: 1, summary: "Lunch", sync_state: "synced"}
    ]

    assert SyncProblems.list([@work, @home], events, MapSet.new([1])) == [
             %{
               integration_id: 1,
               account: "Work account",
               kind: :unreachable,
               pending: ["Dentist"]
             }
           ]
  end

  test "changes waiting on an account that has not failed are named as waiting" do
    assert [%{integration_id: 2, kind: :waiting, pending: ["Gym"]}] =
             SyncProblems.list([@work, @home], [pending(2, "Gym")], MapSet.new())
  end

  test "an account that needs signing in again says so first" do
    assert [%{kind: :reauth}] =
             SyncProblems.list([%{@work | needs_reauth: true}], [], MapSet.new([1]))
  end

  test "nothing to say when every account is fine" do
    assert SyncProblems.list(
             [@work, @home],
             [%{id: 3, kind: :booking, summary: "Call"}],
             MapSet.new()
           ) == []
  end
end
