defmodule TymeslotWeb.Dashboard.Calendar.IcsImport do
  @moduledoc """
  The calendar's `.ics` import. Its state is the `ics_import` assign,
  `nil` until the modal first opens, then a map whose `stage` is one of:

    * `:choose`: waiting for a file, picked in the modal or dropped anywhere
      on the calendar (the upload belongs to the surface root, see
      `ImportModal.drop_zone/1`, so a drop works with the modal closed);
    * `:reading`: the file is planned by `IcsImportFlow.plan/3` in
      an async task (`:ics_import_plan`), so a large file never holds up the
      dashboard;
    * `:too_many`: the file holds more events than one import writes, so
      the organiser chooses a date to import from (`from`, one of the
      `overview`'s importable suggestions) and the file, kept as `content`,
      is planned again from then on;
    * `:ready`: its events are counted (`summary`) and a writable calendar
      is chosen (`calendar_key`, a `CalendarDirectory.key/2`);
    * `:running`: `DashboardLive` writes the events through
      `IcsImportRunner`, which reports `progress/2` and `finished/2` back
      through `CalendarRouting`;
    * `:done`: the result, shown until the modal closes.

  `open` says whether the modal shows. Closing a running import only hides
  it: the import carries on, "Import an .ics file" shows its progress
  again, and its end is toasted whether the modal shows or not.

  One import per organiser at a time: a file arriving while one runs (from
  this surface or another tab) is turned away. The upload options, the
  summary and every message come from `IcsImportFlow`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView,
    only: [allow_upload: 3, cancel_async: 2, cancel_upload: 3, start_async: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.SurfaceMenus
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.IcsImportFlow
  alias TymeslotWeb.Helpers.UploadHandler

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Registers the `.ics` upload on the surface (from `CalendarSurface.mount/1`)."
  @spec allow(socket()) :: socket()
  def allow(socket),
    do:
      allow_upload(
        socket,
        IcsImportFlow.upload_name(),
        IcsImportFlow.upload_options(&upload_progress/3)
      )

  @doc "The writable calendars a file can go to, in rail order."
  @spec choices(map()) :: [map()]
  def choices(assigns), do: CalendarDirectory.choices(assigns.accounts)

  @doc "Answers the import's events (see `PowerEvents`)."
  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:ics_open", params, socket),
    do: {:noreply, socket |> SurfaceMenus.mark_return(params) |> open()}

  def handle(
        "calendar:ics_close",
        _params,
        %{assigns: %{ics_import: %{stage: :running} = state}} = socket
      ),
      do:
        {:noreply,
         socket |> assign(:ics_import, %{state | open: false}) |> SurfaceMenus.restore_focus()}

  # A file still uploading is dropped too, or its arrival would open the
  # modal again; a plan still being read is ignored when it lands.
  def handle("calendar:ics_close", _params, socket),
    do:
      {:noreply,
       socket
       |> cancel_entries()
       |> cancel_async(:ics_import_plan)
       |> assign(:ics_import, nil)
       |> SurfaceMenus.restore_focus()}

  def handle("calendar:ics_validate", _params, socket) do
    if importing?(socket),
      do: {:noreply, turn_away(socket)},
      else: {:noreply, validate(socket)}
  end

  def handle(
        "calendar:ics_calendar",
        %{"calendar" => key},
        %{assigns: %{ics_import: %{stage: :ready} = state}} = socket
      )
      when is_binary(key) do
    if writable?(socket, key),
      do: {:noreply, assign(socket, :ics_import, %{state | calendar_key: key})},
      else: {:noreply, socket}
  end

  def handle(
        "calendar:ics_cutoff",
        %{"from" => from},
        %{assigns: %{ics_import: %{stage: :too_many} = state}} = socket
      )
      when is_binary(from) do
    case Enum.find(
           state.overview.suggestions,
           &(&1.importable and Date.to_iso8601(&1.from) == from)
         ) do
      nil -> {:noreply, socket}
      suggestion -> {:noreply, assign(socket, :ics_import, %{state | from: suggestion.from})}
    end
  end

  def handle(
        "calendar:ics_narrow",
        _params,
        %{assigns: %{ics_import: %{stage: :too_many, from: %Date{} = from}}} = socket
      ),
      do: {:noreply, plan_file(socket, from: from)}

  def handle(
        "calendar:ics_start",
        _params,
        %{assigns: %{ics_import: %{stage: :ready} = state}} = socket
      ),
      do: {:noreply, start(socket, state)}

  def handle(_event, _params, socket), do: {:noreply, socket}

  @doc "Takes the plan of an uploaded file, read by the `:ics_import_plan` task."
  @spec async(:ics_import_plan, term(), socket()) :: {:noreply, socket()}
  def async(
        :ics_import_plan,
        {:ok, {ref, planned}},
        %{assigns: %{ics_import: %{stage: :reading, read_ref: ref}}} = socket
      ),
      do: {:noreply, apply_plan(socket, planned)}

  def async(
        :ics_import_plan,
        {:exit, _reason},
        %{assigns: %{ics_import: %{stage: :reading}}} = socket
      ),
      do: {:noreply, apply_plan(socket, {:error, :invalid_file})}

  # The modal was closed, or a newer file arrived, while this one was read.
  def async(:ics_import_plan, _result, socket), do: {:noreply, socket}

  @doc "Records how many events a running import has handled."
  @spec progress(socket(), non_neg_integer()) :: socket()
  def progress(%{assigns: %{ics_import: %{stage: :running}}} = socket, done),
    do: update_state(socket, &%{&1 | done: done})

  def progress(socket, _done), do: socket

  @doc """
  Ends an import: the toast says how it went, a modal showing it moves to
  `:done`, a hidden one is forgotten, and the events are reloaded. A surface
  mounted since the import began, part way through another file, keeps it.
  """
  @spec finished(socket(), term()) :: socket()
  def finished(socket, result) do
    {kind, message} = IcsImportFlow.result_flash(result)

    socket
    |> Toast.show(message)
    |> finish_state(kind, message)
    |> reload()
  end

  # --- Stages ---

  # Opens the modal, keeping an import under way or a file already chosen;
  # otherwise it starts on the organiser's default calendar. A sheet or
  # dropdown that offered the entry gives way.
  defp open(%{assigns: %{ics_import: %{} = state}} = socket),
    do: assign(socket, ics_import: %{state | open: true}, open_menu: nil, preview: nil)

  defp open(socket) do
    assign(socket,
      open_menu: nil,
      preview: nil,
      ics_import: %{
        open: true,
        stage: :choose,
        error: nil,
        file_name: nil,
        plan: nil,
        summary: nil,
        content: nil,
        overview: nil,
        from: nil,
        calendar_key: default_key(socket.assigns),
        done: 0,
        total: 0,
        result: nil
      }
    )
  end

  defp default_key(assigns) do
    case CalendarDirectory.default_calendar(assigns.integrations) do
      nil -> assigns |> choices() |> List.first(%{}) |> Map.get(:key)
      key -> key
    end
  end

  # A picked or dropped file arrives here first (the form's change event),
  # so the modal is opened for it. A file the upload refused (too large, not
  # an `.ics`) never uploads: it is reported and dropped, leaving the input
  # free for another try.
  defp validate(socket) do
    socket = open(socket)
    name = IcsImportFlow.upload_name()

    case Enum.reject(UploadHandler.upload_entries(socket, name), & &1.valid?) do
      [] ->
        to_choose(socket, %{})

      [entry | _rest] = rejected ->
        reason = socket.assigns.uploads[name] |> upload_errors(entry) |> List.first()
        socket = Enum.reduce(rejected, socket, &cancel_upload(&2, name, &1.ref))

        to_choose(socket, %{file_name: nil, error: IcsImportFlow.upload_error(reason)})
    end
  end

  # Back to choosing a file: whatever was read or reported is forgotten, bar
  # what `extra` sets.
  defp to_choose(socket, extra),
    do: update_state(socket, &clear(&1, Map.put(extra, :stage, :choose)))

  defp clear(state, extra) do
    Map.merge(
      %{
        state
        | plan: nil,
          summary: nil,
          error: nil,
          result: nil,
          content: nil,
          overview: nil,
          from: nil
      },
      extra
    )
  end

  # The upload's own progress callback: the file's arrival, not the form's
  # change event, is what the upload is sure to report.
  defp upload_progress(_name, entry, socket) do
    cond do
      importing?(socket) -> {:noreply, turn_away(socket)}
      entry.done? -> {:noreply, settle(socket)}
      true -> {:noreply, socket}
    end
  end

  defp settle(socket) do
    case UploadHandler.settle_upload(socket, IcsImportFlow.upload_name()) do
      {socket, :settled} -> socket |> open() |> read()
      {socket, :in_progress} -> socket
    end
  end

  defp read(socket) do
    case IcsImportFlow.consume(socket) do
      {:ok, file_name, content} ->
        socket
        |> update_state(&clear(&1, %{file_name: file_name, content: content}))
        |> plan_file([])

      # Nothing finished uploading: leave the socket alone (a refused file was
      # reported at validation).
      :none ->
        socket
    end
  end

  # Only the file is read in `read/1`; parsing a large one takes seconds, so
  # it is planned in an async task and `async/3` takes the result.
  defp plan_file(%{assigns: %{ics_import: %{content: content}}} = socket, opts) do
    timezone = socket.assigns.timezone
    # A later file of the same name must not take this one's plan.
    ref = make_ref()

    socket
    |> update_state(&Map.merge(&1, %{stage: :reading, read_ref: ref, error: nil}))
    |> cancel_async(:ics_import_plan)
    |> start_async(
      :ics_import_plan,
      Tasks.with_context(fn -> {ref, IcsImportFlow.plan(content, timezone, opts)} end)
    )
  end

  # The calendar chosen when the modal opened may have gone (disconnected,
  # hidden from writing) while the file was read: fall back to the default.
  defp apply_plan(socket, {:ok, plan}) do
    default = default_key(socket.assigns)

    update_state(socket, fn state ->
      key =
        if state.calendar_key && writable?(socket, state.calendar_key),
          do: state.calendar_key,
          else: default

      %{
        state
        | stage: :ready,
          plan: plan,
          summary: IcsImportFlow.summary(plan),
          error: nil,
          content: nil,
          overview: nil,
          calendar_key: key
      }
    end)
  end

  # The earliest suggestion that fits is chosen to begin with: it keeps the
  # most of the file.
  defp apply_plan(socket, {:error, {:too_many_events, overview}}) do
    from = Enum.find_value(overview.suggestions, &(&1.importable && &1.from))

    update_state(
      socket,
      &%{&1 | stage: :too_many, overview: overview, from: from, error: nil}
    )
  end

  defp apply_plan(socket, {:error, reason}),
    do: to_choose(socket, %{error: IcsImportFlow.plan_error(reason)})

  # The calendar must be one this organiser can write to (the picker's
  # choices come from their own accounts) and no import of theirs may be
  # running; then the rate limit. `CalendarGrid.IcsImport.target/3` checks ownership
  # again before anything is written.
  defp start(socket, state) do
    user_id = socket.assigns.current_user.id

    with {:ok, integration_id, calendar_id} <- owned_target(socket, state.calendar_key),
         false <- CalendarGrid.ics_import_running?(user_id),
         :ok <- RateLimiter.check(:calendar_ics_import, user_id) do
      send(
        self(),
        {:execute_ics_import,
         %{
           user_id: user_id,
           integration_id: integration_id,
           calendar_id: calendar_id,
           plan: state.plan
         }}
      )

      assign(socket, :ics_import, %{
        state
        | stage: :running,
          done: 0,
          total: length(state.plan.events),
          error: nil
      })
    else
      true ->
        put_error(socket, IcsImportFlow.busy_message())

      {:error, :rate_limited, _message} ->
        put_error(socket, IcsImportFlow.start_error(:rate_limited))

      :error ->
        put_error(socket, IcsImportFlow.start_error(:invalid_calendar))
    end
  end

  defp owned_target(socket, key) do
    with true <- is_binary(key) and writable?(socket, key),
         {:ok, integration_id, calendar_id} <- CalendarDirectory.parse_key(key),
         true <- Enum.any?(socket.assigns.integrations, &(&1.id == integration_id)) do
      {:ok, integration_id, calendar_id}
    else
      _not_theirs -> :error
    end
  end

  defp writable?(socket, key), do: Enum.any?(choices(socket.assigns), &(&1.key == key))

  defp finish_state(
         %{assigns: %{ics_import: %{stage: :running, open: true} = state}} = socket,
         kind,
         message
       ),
       do: assign(socket, :ics_import, %{state | stage: :done, result: {kind, message}})

  defp finish_state(%{assigns: %{ics_import: %{stage: :running}}} = socket, _kind, _message),
    do: assign(socket, :ics_import, nil)

  defp finish_state(socket, _kind, _message), do: socket

  defp reload(socket),
    do: if(socket.assigns.ready?, do: SurfaceData.reload(socket, :events), else: socket)

  defp importing?(%{assigns: %{ics_import: %{stage: :running}}}), do: true

  defp importing?(socket),
    do: CalendarGrid.ics_import_running?(socket.assigns.current_user.id)

  # A file arriving while an import runs is dropped; the modal shows that
  # import, or says one is running when this surface did not start it.
  defp turn_away(%{assigns: %{ics_import: %{stage: :running}}} = socket),
    do: socket |> cancel_entries() |> open() |> put_error(IcsImportFlow.busy_message())

  defp turn_away(socket) do
    socket
    |> cancel_entries()
    |> cancel_async(:ics_import_plan)
    |> open()
    |> to_choose(%{error: IcsImportFlow.busy_message()})
  end

  defp cancel_entries(socket) do
    name = IcsImportFlow.upload_name()

    socket
    |> UploadHandler.upload_entries(name)
    |> Enum.reduce(socket, &cancel_upload(&2, name, &1.ref))
  end

  defp put_error(socket, message), do: update_state(socket, &%{&1 | error: message})

  defp update_state(%{assigns: %{ics_import: %{} = state}} = socket, fun),
    do: assign(socket, :ics_import, fun.(state))

  defp update_state(socket, _fun), do: socket
end
