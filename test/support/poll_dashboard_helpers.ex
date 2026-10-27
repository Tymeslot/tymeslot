defmodule TymeslotWeb.PollDashboardHelpers do
  @moduledoc """
  Helpers for LiveView tests of the dashboard's poll panels.
  """
  import Phoenix.LiveViewTest
  import Tymeslot.TestHelpers.Eventually

  @doc """
  Waits until the results panel has applied its calendar conflict check.

  Opening an open poll's results, or a refused confirm, starts the check in a
  supervised task that calls the calendar mock. A test that ends before the
  task gets there leaves it calling a mock whose stubs went with the test
  process, which logs a `Mox.UnexpectedCallError`. Call this after any such
  interaction the test does not otherwise wait on. Rendering is a call to the
  LiveView, so once the "checking" line is gone the task has finished with the
  calendar.
  """
  @spec await_slot_health(Phoenix.LiveViewTest.View.t()) :: true
  def await_slot_health(view) do
    eventually(fn -> not has_element?(view, "[data-testid='poll-slot-health-checking']") end,
      timeout: 10_000,
      message: "the poll's calendar conflict check never finished"
    )
  end
end
