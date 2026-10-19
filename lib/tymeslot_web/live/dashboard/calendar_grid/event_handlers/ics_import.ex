defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.IcsImport do
  @moduledoc """
  The calendar grid's `.ics` import flow (presentation layer).

  The import modal walks through three stages, held in the `:ics_import`
  assign:

    * `:choose` - waiting for a file. The upload runs as soon as one is
      picked, and its contents are planned by `CalendarGrid.plan_ics_import/2`
      in an async task (`:reading` is set meanwhile), so a large file never
      holds up the dashboard,
    * `:ready` - the file's events are known and a calendar is picked, and
    * `:running` - the events are being written by a supervised task the
      dashboard LiveView owns (see `IcsImportRunner`), which reports
      progress and the result back through `send_update/2`.

  The file input belongs to the grid rather than the modal, so a file dropped
  anywhere on the calendar is uploaded too, opening the modal on arrival.

  Closing the modal while an import runs only hides it: the import carries on
  and reopening shows its progress. When it ends the modal closes and the
  outcome is flashed.

  The upload's options, reading and planning the file, and every message
  live in `TymeslotWeb.Dashboard.IcsImportFlow`, which the new calendar uses
  too; this module keeps the old grid's stages.

  A user runs one import at a time. The grid's own `:running` stage covers the
  import it started; one started from another tab, or before the grid was last
  mounted, is found through `CalendarGrid.ics_import_running?/1`, and a new
  file is turned away while either is under way.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3, upload_errors: 2]

  import Phoenix.LiveView, only: [cancel_upload: 3, start_async: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.IcsImport
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.IcsImportFlow
  alias TymeslotWeb.Helpers.UploadHandler

  @upload IcsImportFlow.upload_name()
  @plan_task :ics_import_plan

  @doc "The upload options the grid component registers its `.ics` upload with."
  @spec upload_options() :: keyword()
  def upload_options, do: IcsImportFlow.upload_options(&handle_upload_progress/3)

  @doc "The name of the grid component's `.ics` upload."
  @spec upload_name() :: atom()
  def upload_name, do: IcsImportFlow.upload_name()

  @spec handle_show(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show(_params, socket), do: {:noreply, open_modal(socket)}

  @spec handle_close(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close(_params, %{assigns: %{ics_import: %{stage: :running} = state}} = socket),
    do: {:noreply, assign(socket, :ics_import, %{state | open: false})}

  # A file still uploading is dropped too, or its arrival would open the modal
  # again; a plan still being read is ignored when it lands.
  def handle_close(_params, socket),
    do: {:noreply, socket |> cancel_entries() |> assign(:ics_import, nil)}

  # A file picked in the modal or dropped anywhere on the calendar arrives
  # here, and a drop can arrive with the modal closed, so the modal is opened
  # for it. While an import runs a new file is turned away: the modal shows the
  # running import instead.
  #
  # A file the upload refused (too large, not an `.ics`) never uploads, so it
  # is reported here and dropped, leaving the input free for another try.
  @spec handle_validate(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate(params, socket) do
    if importing?(socket),
      do: {:noreply, turn_away(socket)},
      else: validate_upload(params, socket)
  end

  defp validate_upload(_params, socket) do
    socket = open_modal(socket)

    rejected =
      Enum.filter(UploadHandler.upload_entries(socket, @upload), &(not &1.valid?))

    case rejected do
      # The new file replaces any plan of an earlier one, which must not be
      # importable while the new one uploads.
      [] ->
        {:noreply, update_state(socket, &%{&1 | stage: :choose, plan: nil, error: nil})}

      [entry | _rest] ->
        message =
          socket.assigns.uploads[@upload]
          |> upload_errors(entry)
          |> List.first()
          |> IcsImportFlow.upload_error()

        socket = Enum.reduce(rejected, socket, &cancel_upload(&2, @upload, &1.ref))

        {:noreply,
         update_state(
           socket,
           &%{&1 | error: message, plan: nil, stage: :choose, reading: false, file_name: nil}
         )}
    end
  end

  @spec handle_select_calendar(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_select_calendar(params, socket) do
    case Shared.parse_int(params["integration-id"]) do
      {:ok, id} ->
        calendar_id =
          params["calendar-id"] ||
            EditWorkflow.default_calendar_id(socket.assigns.integrations, id)

        {:noreply, update_state(socket, &%{&1 | integration_id: id, calendar_id: calendar_id})}

      :error ->
        {:noreply, socket}
    end
  end

  @spec handle_start(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_start(_params, %{assigns: %{ics_import: %{stage: :ready} = state}} = socket) do
    user_id = socket.assigns.current_user.id

    with :ok <- EditWorkflow.assert_owns_integration(socket, state.integration_id),
         false <- CalendarGrid.ics_import_running?(user_id),
         :ok <- RateLimiter.check(:calendar_ics_import, user_id) do
      send(
        self(),
        {:execute_ics_import,
         %{
           user_id: user_id,
           integration_id: state.integration_id,
           calendar_id: state.calendar_id,
           plan: state.plan
         }}
      )

      {:noreply, assign(socket, :ics_import, %{state | stage: :running, done: 0, error: nil})}
    else
      true ->
        {:noreply, update_state(socket, &%{&1 | error: IcsImportFlow.busy_message()})}

      {:error, :rate_limited, _message} ->
        {:noreply,
         update_state(
           socket,
           &%{
             &1
             | error: IcsImportFlow.start_error(:rate_limited)
           }
         )}

      {:error, _unauthorized} ->
        {:noreply,
         update_state(
           socket,
           &%{&1 | error: IcsImportFlow.start_error(:invalid_calendar)}
         )}
    end
  end

  def handle_start(_params, socket), do: {:noreply, socket}

  @doc "Records how many events a running import has handled."
  @spec handle_progress(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def handle_progress(%{done: done}, %{assigns: %{ics_import: %{stage: :running}}} = socket),
    do: {:ok, update_state(socket, &%{&1 | done: done})}

  def handle_progress(_assigns, socket), do: {:ok, socket}

  @doc """
  Ends an import: its outcome is flashed, the modal closes if it was showing
  that import, and the grid reloads once the calendar's sync brings the
  imported events in.

  The grid may have been mounted again since the import began, and be part
  way through choosing another file; that is left alone.
  """
  @spec handle_finished(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def handle_finished(%{result: result}, socket) do
    send(self(), {:flash, IcsImportFlow.result_flash(result)})

    case socket.assigns.ics_import do
      %{stage: :running} -> {:ok, assign(socket, :ics_import, nil)}
      _other -> {:ok, socket}
    end
  end

  @doc "Takes the plan of an uploaded file, read by an async task."
  @spec handle_planned(
          {:ok, {String.t(), {:ok, IcsImport.plan()} | {:error, atom()}}} | {:exit, term()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_planned(
        {:ok, {file_name, planned}},
        %{assigns: %{ics_import: %{reading: true}}} = socket
      ),
      do: {:noreply, apply_plan(socket, file_name, planned)}

  def handle_planned({:exit, _reason}, %{assigns: %{ics_import: %{reading: true}}} = socket),
    do:
      {:noreply, apply_plan(socket, socket.assigns.ics_import.file_name, {:error, :invalid_file})}

  # The modal was closed, or an import started, while the file was read.
  def handle_planned(_result, socket), do: {:noreply, socket}

  # --- Upload ---

  # Opens the modal as `handle_validate/2` does: the file's arrival, not the
  # form's change event, is what the upload is sure to report.
  defp handle_upload_progress(_config, entry, socket) do
    cond do
      importing?(socket) -> {:noreply, turn_away(socket)}
      entry.done? -> settle_upload(socket)
      true -> {:noreply, socket}
    end
  end

  defp settle_upload(socket) do
    case UploadHandler.settle_upload(socket, @upload) do
      {socket, :settled} -> {:noreply, socket |> open_modal() |> plan_upload()}
      {socket, :in_progress} -> {:noreply, socket}
    end
  end

  defp importing?(%{assigns: %{ics_import: %{stage: :running}}}), do: true

  defp importing?(socket),
    do: CalendarGrid.ics_import_running?(socket.assigns.current_user.id)

  # A file arriving while an import is under way is dropped, and the modal
  # shows that import, or says one is running when this grid did not start it.
  defp turn_away(%{assigns: %{ics_import: %{stage: :running}}} = socket),
    do: socket |> cancel_entries() |> open_modal()

  defp turn_away(socket) do
    socket
    |> cancel_entries()
    |> open_modal()
    |> update_state(
      &%{&1 | error: IcsImportFlow.busy_message(), stage: :choose, plan: nil, reading: false}
    )
  end

  defp cancel_entries(socket) do
    socket
    |> UploadHandler.upload_entries(@upload)
    |> Enum.reduce(socket, &cancel_upload(&2, @upload, &1.ref))
  end

  # Opens the modal, keeping an import already under way or a file already
  # chosen; otherwise it starts on the user's default calendar.
  defp open_modal(%{assigns: %{ics_import: %{} = state}} = socket),
    do: assign(socket, :ics_import, %{state | open: true})

  defp open_modal(socket) do
    integration_id = EditWorkflow.default_integration_id(socket)

    assign(socket, :ics_import, %{
      open: true,
      stage: :choose,
      error: nil,
      file_name: nil,
      plan: nil,
      integration_id: integration_id,
      calendar_id: EditWorkflow.default_calendar_id(socket.assigns.integrations, integration_id),
      done: 0,
      reading: false
    })
  end

  # Only the file is read here; parsing a large one takes seconds, so it runs
  # in an async task and `handle_planned/2` takes the result. A newer file's
  # task replaces an older one still running.
  defp plan_upload(socket) do
    case IcsImportFlow.consume(socket) do
      :none ->
        socket

      {:ok, file_name, content} ->
        timezone = socket.assigns.user_timezone

        socket
        |> update_state(
          &%{&1 | stage: :choose, plan: nil, file_name: file_name, error: nil, reading: true}
        )
        |> start_async(
          @plan_task,
          Tasks.with_context(fn -> {file_name, IcsImportFlow.plan(content, timezone)} end)
        )
    end
  end

  defp apply_plan(socket, file_name, {:ok, plan}) do
    update_state(
      socket,
      &%{&1 | stage: :ready, plan: plan, file_name: file_name, error: nil, reading: false}
    )
  end

  defp apply_plan(socket, file_name, {:error, reason}) do
    update_state(
      socket,
      &%{
        &1
        | stage: :choose,
          plan: nil,
          file_name: file_name,
          error: IcsImportFlow.plan_error(reason),
          reading: false
      }
    )
  end

  defp update_state(%{assigns: %{ics_import: %{} = state}} = socket, fun),
    do: assign(socket, :ics_import, fun.(state))

  defp update_state(socket, _fun), do: socket
end
