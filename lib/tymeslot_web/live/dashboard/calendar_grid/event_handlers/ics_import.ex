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
      dashboard LiveView owns (see `CalendarEventHandlers`), which reports
      progress and the result back through `send_update/2`.

  The file input belongs to the grid rather than the modal, so a file dropped
  anywhere on the calendar is uploaded too, opening the modal on arrival.

  Closing the modal while an import runs only hides it: the import carries on
  and reopening shows its progress. When it ends the modal closes and the
  outcome is flashed.

  A user runs one import at a time. The grid's own `:running` stage covers the
  import it started; one started from another tab, or before the grid was last
  mounted, is found through `CalendarGrid.ics_import_running?/1`, and a new
  file is turned away while either is under way.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3, upload_errors: 2]

  import Phoenix.LiveView,
    only: [cancel_upload: 3, consume_uploaded_entries: 3, start_async: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.IcsImport
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Helpers.UploadHandler

  @upload :ics_file
  @plan_task :ics_import_plan

  @doc "The upload options the grid component registers its `.ics` upload with."
  @spec upload_options() :: keyword()
  def upload_options do
    [
      accept: ~w(.ics),
      max_entries: 1,
      max_file_size: IcsImport.max_bytes(),
      auto_upload: true,
      progress: &handle_upload_progress/3
    ]
  end

  @doc "The name of the grid component's `.ics` upload."
  @spec upload_name() :: atom()
  def upload_name, do: @upload

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
          |> upload_error_message()

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
         :ok <- RateLimiter.check_calendar_ics_import_rate_limit(user_id) do
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
        {:noreply, update_state(socket, &%{&1 | error: busy_message()})}

      {:error, :rate_limited, _message} ->
        {:noreply,
         update_state(
           socket,
           &%{
             &1
             | error:
                 dgettext(
                   "dashboard_calendar_events",
                   "Too many imports. Please wait a while before importing another file."
                 )
           }
         )}

      {:error, _unauthorized} ->
        {:noreply,
         update_state(
           socket,
           &%{&1 | error: dgettext("dashboard_calendar_events", "Invalid calendar selected")}
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
    send(self(), {:flash, result_flash(result)})

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

  @doc "The flash an import's result is reported with."
  @spec result_flash({:ok, IcsImport.summary()} | {:error, term()}) ::
          {:info | :warning | :error, String.t()}
  def result_flash({:ok, %{failed: 0, exclusions_dropped: 0} = summary}),
    do: {:info, created_message(summary.created)}

  # Nothing was written, so there is no import to report, only why.
  def result_flash({:ok, %{created: 0, halted: nil} = summary}),
    do: {:error, failed_message(summary)}

  def result_flash({:ok, %{created: 0, halted: reason}}), do: {:error, halted_message(reason)}

  def result_flash({:ok, summary}) do
    parts =
      [
        created_message(summary.created),
        summary.failed > 0 && failed_message(summary),
        summary.halted && halted_message(summary.halted),
        summary.exclusions_dropped > 0 && exclusions_message(summary.exclusions_dropped)
      ]

    {:warning, parts |> Enum.filter(&is_binary/1) |> Enum.join(" ")}
  end

  def result_flash({:error, :already_running}), do: {:error, busy_message()}

  def result_flash({:error, :failed}),
    do:
      {:error,
       dgettext(
         "dashboard_calendar_events",
         "The import could not be finished. Some of its events may already be in your calendar."
       )}

  def result_flash({:error, _reason}),
    do: {:error, dgettext("dashboard_calendar_events", "Invalid calendar selected")}

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
    |> update_state(&%{&1 | error: busy_message(), stage: :choose, plan: nil, reading: false})
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
    consumed =
      consume_uploaded_entries(socket, @upload, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    case consumed do
      [] ->
        socket

      [{file_name, content}] ->
        timezone = socket.assigns.user_timezone

        socket
        |> update_state(
          &%{&1 | stage: :choose, plan: nil, file_name: file_name, error: nil, reading: true}
        )
        |> start_async(
          @plan_task,
          Tasks.with_context(fn ->
            {file_name, CalendarGrid.plan_ics_import(content, timezone)}
          end)
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
          error: plan_error_message(reason),
          reading: false
      }
    )
  end

  defp update_state(%{assigns: %{ics_import: %{} = state}} = socket, fun),
    do: assign(socket, :ics_import, fun.(state))

  defp update_state(socket, _fun), do: socket

  # --- Messages ---

  defp busy_message,
    do:
      dgettext(
        "dashboard_calendar_events",
        "An import is still running. Please wait for it to finish before importing another file."
      )

  defp upload_error_message(:too_large),
    do:
      dgettext(
        "dashboard_calendar_events",
        "The file is too large. Files up to %{size} MB can be imported.",
        size: div(IcsImport.max_bytes(), 1_000_000)
      )

  defp upload_error_message(:not_accepted),
    do: dgettext("dashboard_calendar_events", "Only .ics calendar files can be imported.")

  defp upload_error_message(_other),
    do: dgettext("dashboard_calendar_events", "The file could not be uploaded. Please try again.")

  defp plan_error_message(:too_large), do: upload_error_message(:too_large)

  defp plan_error_message(:invalid_file),
    do:
      dgettext(
        "dashboard_calendar_events",
        "This file could not be read as a calendar. Please choose an .ics file."
      )

  defp plan_error_message(:no_events),
    do: dgettext("dashboard_calendar_events", "This file contains no events to import.")

  defp plan_error_message(:too_many_events),
    do:
      dgettext(
        "dashboard_calendar_events",
        "This file contains more than %{count} events. Please split it into smaller files.",
        count: IcsImport.max_events()
      )

  defp created_message(count),
    do:
      dngettext(
        "dashboard_calendar_events",
        "Imported 1 event.",
        "Imported %{count} events.",
        count
      )

  defp failed_message(%{failed: failed, failed_titles: titles}) do
    titles = titles |> Enum.reject(&(&1 == "")) |> Enum.join(", ")

    message =
      dngettext(
        "dashboard_calendar_events",
        "1 event could not be imported.",
        "%{count} events could not be imported.",
        failed
      )

    if titles == "", do: message, else: "#{message} (#{titles})"
  end

  defp halted_message(:unauthorized),
    do:
      dgettext(
        "dashboard_calendar_events",
        "The import stopped because your calendar needs to be reconnected."
      )

  defp halted_message(reason) when reason in [:unavailable, :circuit_open],
    do:
      dgettext(
        "dashboard_calendar_events",
        "The import stopped because your calendar is not responding. Please try again later."
      )

  defp halted_message(_reason),
    do:
      dgettext(
        "dashboard_calendar_events",
        "The import stopped because the calendar could not be written to."
      )

  defp exclusions_message(count),
    do:
      dngettext(
        "dashboard_calendar_events",
        "Outlook could not take the skipped dates of 1 recurring event, so it may show extra occurrences.",
        "Outlook could not take the skipped dates of %{count} recurring events, so they may show extra occurrences.",
        count
      )
end
