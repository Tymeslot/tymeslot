defmodule TymeslotWeb.Dashboard.IcsImportRunner do
  @moduledoc """
  Writes an `.ics` import the calendar started, for `DashboardLive`.

  The calendar on screen sends `{:execute_ics_import, payload}` (payload
  `%{user_id, integration_id, calendar_id, plan}`) once the organiser starts
  an import; `CalendarMessages` hands it, the progress and the result here.
  Progress and the result go to the calendar that is mounted through
  `CalendarRouting.to_mounted/2` (`action: :ics_import_progress, done: n` and
  `action: :ics_import_finished, result: result`); off the calendar page the
  result is flashed with `IcsImportFlow.result_flash/1`.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.Dashboard.CalendarRouting
  alias TymeslotWeb.Dashboard.IcsImportFlow

  require Logger

  @type socket :: Phoenix.LiveView.Socket.t()

  # A send_update re-renders the whole calendar, so a long import reports its
  # progress every few events rather than after each one.
  @progress_every 10

  @doc """
  Spawns a supervised task that imports an `.ics` plan into a calendar,
  reporting progress and the result back to this LiveView.

  The task is not linked: an import the user walked away from still finishes,
  rather than stopping part-way with some of the file's events written.
  """
  @spec execute(map(), socket()) :: {:noreply, socket()}
  def execute(payload, socket) do
    lv_pid = self()
    total = length(payload.plan.events)

    on_progress = fn done ->
      if rem(done, @progress_every) == 0 or done == total,
        do: send(lv_pid, {:ics_import_progress, done})
    end

    Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:ics_import_result, run(payload, on_progress)})
    end)

    {:noreply, socket}
  end

  @doc "Passes a running import's progress to the calendar on screen."
  @spec progress(non_neg_integer(), socket()) :: {:noreply, socket()}
  def progress(done, socket) do
    CalendarRouting.to_mounted(socket, action: :ics_import_progress, done: done)
    {:noreply, socket}
  end

  @doc """
  Hands a finished import to the calendar on screen, which reports the
  outcome; off the calendar page the outcome is flashed here.
  """
  @spec result(term(), socket()) :: {:noreply, socket()}
  def result(result, %{assigns: %{live_action: :calendar}} = socket) do
    CalendarRouting.to_mounted(socket, action: :ics_import_finished, result: result)
    {:noreply, socket}
  end

  def result(result, socket) do
    {kind, message} = IcsImportFlow.result_flash(result)
    {:noreply, put_flash(socket, kind, message)}
  end

  # Whatever happens, the LiveView hears how the import ended; otherwise its
  # modal would show the import running until the page is reloaded.
  defp run(payload, on_progress) do
    CalendarGrid.import_ics(
      payload.user_id,
      payload.integration_id,
      payload.calendar_id,
      payload.plan,
      on_progress: on_progress
    )
  catch
    kind, reason ->
      Logger.error("ICS import failed",
        user_id: payload.user_id,
        kind: kind,
        error: LogFormat.reason(reason),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )

      {:error, :failed}
  end
end
