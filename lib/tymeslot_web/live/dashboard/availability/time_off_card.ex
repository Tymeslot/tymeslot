defmodule TymeslotWeb.Dashboard.Availability.TimeOffCard do
  @moduledoc """
  Time-off card for the availability page.

  Holidays and other stretches away belong to the person, not to one named
  schedule, so this card sits outside the schedule panel and says so: whatever
  is listed here applies to every schedule and every meeting type the profile
  owns. Putting it inside the panel would invite the reading that switching
  tabs switches the holiday too.

  The card owns its own list and its own modals rather than pushing that state
  up to `ScheduleSettingsComponent`, which is already the page's schedule
  editor and shares none of these assigns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.LiveView.JS
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  alias TymeslotWeb.Components.Dashboard.Availability.{DeleteTimeOffModal, TimeOffFormModal}
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  # Fields the form renders an inline error under. Anything else the changeset
  # can complain about has no home in the form and becomes a flash instead.
  @form_fields [:starts_on, :ends_on, :start_time, :end_time, :label]

  @impl Phoenix.LiveComponent
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok, ModalHook.mount_modal(socket, time_off_form: false, delete_time_off: false)}
  end

  @impl Phoenix.LiveComponent
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> load_periods()}
  end

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("show_time_off_form", %{"id" => id}, socket) do
    case fetch_period(socket, id) do
      {:ok, period} ->
        {:noreply, ModalHook.show_modal(socket, :time_off_form, edit_data(period))}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_availability", "That time off no longer exists"))
        {:noreply, load_periods(socket)}
    end
  end

  def handle_event("show_time_off_form", _params, socket) do
    if TimeOff.can_create?(profile_id(socket)) do
      {:noreply, ModalHook.show_modal(socket, :time_off_form, blank_data())}
    else
      Flash.error(
        dgettext(
          "dashboard_availability",
          "You already have the maximum of %{count} time off periods",
          count: TimeOff.max_periods()
        )
      )

      {:noreply, socket}
    end
  end

  def handle_event("hide_time_off_form", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :time_off_form)}
  end

  def handle_event("save_time_off", params, socket) do
    ModalHook.with_modal_data(socket, :time_off_form, fn data ->
      {:noreply, save(socket, data, attrs_from(params))}
    end)
  end

  def handle_event("show_delete_time_off", %{"id" => id}, socket) do
    case fetch_period(socket, id) do
      {:ok, period} ->
        {:noreply,
         ModalHook.show_modal(socket, :delete_time_off, %{
           id: period.id,
           summary: range_summary(period, socket.assigns.time_format)
         })}

      {:error, _reason} ->
        {:noreply, load_periods(socket)}
    end
  end

  def handle_event("hide_delete_time_off", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete_time_off)}
  end

  def handle_event("confirm_delete_time_off", _params, socket) do
    ModalHook.with_modal_data(socket, :delete_time_off, fn %{id: id} ->
      {:noreply, delete(socket, id)}
    end)
  end

  defp save(socket, %{mode: :edit, id: id}, attrs) do
    with {:ok, period} <- TimeOff.fetch(profile_id(socket), id),
         {:ok, _updated} <- TimeOff.update(period, attrs) do
      saved(socket, dgettext("dashboard_availability", "Time off updated"))
    else
      {:error, reason} -> save_failed(socket, reason, attrs, :edit, id)
    end
  end

  defp save(socket, _create, attrs) do
    case TimeOff.create(profile_id(socket), attrs) do
      {:ok, _period} -> saved(socket, dgettext("dashboard_availability", "Time off added"))
      {:error, reason} -> save_failed(socket, reason, attrs, :create, nil)
    end
  end

  defp saved(socket, message) do
    Flash.info(message)

    socket
    |> ModalHook.hide_modal(:time_off_form)
    |> load_periods()
  end

  # The form stays open carrying what was typed, with the changeset's messages
  # under the fields they belong to; a validation failure that closed the modal
  # would discard the dates the user had just chosen.
  defp save_failed(socket, %Changeset{} = changeset, attrs, mode, id) do
    data =
      attrs
      |> form_data(mode, id)
      |> Map.put(:errors, form_errors(changeset))

    if map_size(data.errors) == 0 do
      Flash.error(dgettext("dashboard_availability", "Could not save your time off"))
    end

    ModalHook.show_modal(socket, :time_off_form, data)
  end

  defp save_failed(socket, :limit_reached, _attrs, _mode, _id) do
    Flash.error(
      dgettext(
        "dashboard_availability",
        "You already have the maximum of %{count} time off periods",
        count: TimeOff.max_periods()
      )
    )

    ModalHook.hide_modal(socket, :time_off_form)
  end

  defp save_failed(socket, :not_found, _attrs, _mode, _id) do
    Flash.error(dgettext("dashboard_availability", "That time off no longer exists"))

    socket
    |> ModalHook.hide_modal(:time_off_form)
    |> load_periods()
  end

  defp delete(socket, id) do
    with {:ok, period} <- TimeOff.fetch(profile_id(socket), id),
         {:ok, _deleted} <- TimeOff.delete(period) do
      Flash.info(dgettext("dashboard_availability", "Time off removed"))
    else
      _other -> Flash.error(dgettext("dashboard_availability", "Could not remove your time off"))
    end

    socket
    |> ModalHook.hide_modal(:delete_time_off)
    |> load_periods()
  end

  defp fetch_period(socket, id) do
    case Integer.parse(to_string(id)) do
      {parsed, ""} -> TimeOff.fetch(profile_id(socket), parsed)
      _other -> {:error, :not_found}
    end
  end

  defp load_periods(socket), do: assign(socket, :periods, TimeOff.list(profile_id(socket)))

  defp profile_id(socket), do: socket.assigns.profile.id

  defp attrs_from(params) do
    Map.new(@form_fields, fn field ->
      {field, params |> Map.get(to_string(field), "") |> String.trim()}
    end)
  end

  defp blank_data do
    @form_fields
    |> Map.new(&{&1, ""})
    |> Map.merge(%{mode: :create, id: nil, errors: %{}})
  end

  defp edit_data(period) do
    %{
      mode: :edit,
      id: period.id,
      errors: %{},
      starts_on: Date.to_iso8601(period.starts_on),
      ends_on: Date.to_iso8601(period.ends_on),
      start_time: wire_time(period.start_time),
      end_time: wire_time(period.end_time),
      label: period.label || ""
    }
  end

  defp form_data(attrs, mode, id) do
    attrs
    |> Map.take(@form_fields)
    |> Map.merge(%{mode: mode, id: id})
  end

  defp form_errors(changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.take(@form_fields)
    |> Map.new(fn {field, messages} -> {field, List.first(messages)} end)
  end

  # The wire format the time dropdown submits, which is 24h whatever clock the
  # organiser reads; `TimeFormat.format/2` is for showing a time to someone.
  defp wire_time(nil), do: ""
  defp wire_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="card-glass shadow-2xl shadow-tymeslot-200/50">
      <div class="flex flex-wrap items-start justify-between gap-4 mb-4">
        <.section_header
          level={2}
          icon="hero-sun"
          title={dgettext("dashboard_availability", "Time Off")}
        />

        <.action_button
          variant={:secondary}
          phx-click="show_time_off_form"
          phx-target={@myself}
          data-testid="add-time-off"
        >
          <.icon name="hero-plus" class="w-4 h-4" />
          {dgettext("dashboard_availability", "Add time off")}
        </.action_button>
      </div>

      <p class="mb-8 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "Days you are away. These apply to every schedule and every meeting type, and nobody booking you sees why those days are closed."
        )}
      </p>

      <.empty_state
        :if={@periods == []}
        message={dgettext("dashboard_availability", "No time off booked")}
        secondary_message={
          dgettext(
            "dashboard_availability",
            "Add a period and those days stop being offered, without touching your calendars."
          )
        }
      >
        <:icon>
          <.icon name="hero-sun" class="w-8 h-8 text-tymeslot-300" />
        </:icon>
      </.empty_state>

      <ul :if={@periods != []} class="space-y-3" data-testid="time-off-list">
        <li
          :for={period <- @periods}
          class="flex flex-wrap items-center justify-between gap-3 rounded-token-xl border border-tymeslot-100 bg-tymeslot-50 px-4 py-3"
        >
          <div class="min-w-0">
            <p class="font-bold text-tymeslot-700">{range_summary(period, @time_format)}</p>
            <p :if={period.label} class="text-token-sm text-tymeslot-500 font-medium truncate">
              {period.label}
            </p>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <button
              type="button"
              phx-click="show_time_off_form"
              phx-value-id={period.id}
              phx-target={@myself}
              class="text-tymeslot-400 hover:text-turquoise-600 transition-colors"
              aria-label={dgettext("dashboard_availability", "Edit time off")}
            >
              <.icon name="hero-pencil-square" class="w-5 h-5" />
            </button>
            <button
              type="button"
              phx-click="show_delete_time_off"
              phx-value-id={period.id}
              phx-target={@myself}
              class="text-tymeslot-300 hover:text-red-500 transition-colors"
              aria-label={dgettext("dashboard_availability", "Remove time off")}
            >
              <.icon name="hero-trash" class="w-5 h-5" />
            </button>
          </div>
        </li>
      </ul>

      <TimeOffFormModal.time_off_form_modal
        id="time-off-form-modal"
        show={@show_time_off_form_modal}
        period_data={@time_off_form_modal_data}
        time_format={@time_format}
        on_cancel={JS.push("hide_time_off_form", target: @myself)}
        myself={@myself}
      />

      <DeleteTimeOffModal.delete_time_off_modal
        id="delete-time-off-modal"
        show={@show_delete_time_off_modal}
        period_data={@delete_time_off_modal_data}
        on_cancel={JS.push("hide_delete_time_off", target: @myself)}
        on_confirm={JS.push("confirm_delete_time_off", target: @myself)}
      />
    </div>
    """
  end

  @doc """
  One line describing when a period runs, as the list row and the delete
  confirmation both show it.

  A whole-day period reads as dates alone; the times appear only where they
  actually trim a day, so a plain holiday is not dressed up as "00:00 to
  23:59".
  """
  @spec range_summary(TimeOff.period(), String.t()) :: String.t()
  def range_summary(period, time_format) do
    period
    |> dates_summary()
    |> append_time(period.start_time, time_format, :from)
    |> append_time(period.end_time, time_format, :until)
  end

  defp dates_summary(%{starts_on: same, ends_on: same}),
    do: LocalizationHelpers.format_date(same)

  defp dates_summary(%{starts_on: starts_on, ends_on: ends_on}) do
    dgettext("dashboard_availability", "%{from} to %{to}",
      from: LocalizationHelpers.format_date(starts_on),
      to: LocalizationHelpers.format_date(ends_on)
    )
  end

  defp append_time(summary, nil, _time_format, _position), do: summary

  defp append_time(summary, %Time{} = time, time_format, :from) do
    dgettext("dashboard_availability", "%{range}, from %{time}",
      range: summary,
      time: TimeFormat.format(time, time_format)
    )
  end

  defp append_time(summary, %Time{} = time, time_format, :until) do
    dgettext("dashboard_availability", "%{range}, until %{time}",
      range: summary,
      time: TimeFormat.format(time, time_format)
    )
  end
end
