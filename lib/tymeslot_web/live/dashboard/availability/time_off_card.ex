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
  alias Tymeslot.Profiles

  alias TymeslotWeb.Components.Dashboard.Availability.{
    DeleteTimeOffModal,
    TimeOffFormModal,
    TimeOffPeriodRow
  }

  alias TymeslotWeb.Dashboard.Availability.TimeOffForm

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
        {:noreply,
         ModalHook.show_modal(
           socket,
           :time_off_form,
           TimeOffForm.edit(period, TimeOff.today(socket.assigns.profile.timezone))
         )}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_availability_time_off", "That time off no longer exists"))
        {:noreply, load_periods(socket)}
    end
  end

  def handle_event("show_time_off_form", _params, socket) do
    if TimeOff.can_create?(profile_id(socket)) do
      {:noreply,
       ModalHook.show_modal(
         socket,
         :time_off_form,
         TimeOffForm.blank(TimeOff.today(socket.assigns.profile.timezone))
       )}
    else
      Flash.error(
        dgettext(
          "dashboard_availability_time_off",
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

  # Runs the same rules as saving, on every change, so a date in the past or a
  # backwards range is flagged beside its field before the form is submitted.
  def handle_event("validate_time_off", params, socket) do
    ModalHook.with_modal_data(socket, :time_off_form, fn data ->
      {:noreply,
       ModalHook.show_modal(
         socket,
         :time_off_form,
         TimeOffForm.validate(
           data,
           TimeOffForm.attrs_from(params),
           profile_id(socket),
           TimeOff.today(socket.assigns.profile.timezone)
         )
       )}
    end)
  end

  def handle_event("save_time_off", params, socket) do
    ModalHook.with_modal_data(socket, :time_off_form, fn data ->
      {:noreply, save(socket, data, TimeOffForm.attrs_from(params))}
    end)
  end

  def handle_event("show_delete_time_off", %{"id" => id}, socket) do
    case fetch_period(socket, id) do
      {:ok, period} ->
        {:noreply,
         ModalHook.show_modal(socket, :delete_time_off, %{
           id: period.id,
           summary: TimeOffPeriodRow.range_summary(period, socket.assigns.time_format)
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

  # A finished period is removed in place, without the confirmation dialog: it
  # no longer affects availability, so there is nothing for the dialog to
  # protect. The row crosses itself out and fades on the client; the context
  # keeps a period that has not ended from being removed this way.
  def handle_event("delete_past_time_off", %{"id" => id}, socket) do
    today = TimeOff.today(socket.assigns.profile.timezone)

    with {:ok, id} <- parse_id(id),
         {:ok, _deleted} <- TimeOff.delete_ended(profile_id(socket), id, today) do
      :ok
    else
      _other ->
        Flash.error(dgettext("dashboard_availability_time_off", "Could not remove your time off"))
    end

    {:noreply, load_periods(socket)}
  end

  defp save(socket, %{mode: :edit, id: id} = data, attrs) do
    with {:ok, period} <- TimeOff.fetch(profile_id(socket), id),
         {:ok, updated} <- TimeOff.update(period, attrs) do
      saved(socket, updated, dgettext("dashboard_availability_time_off", "Time off updated"))
    else
      {:error, reason} -> save_failed(socket, reason, data, attrs)
    end
  end

  defp save(socket, data, attrs) do
    case TimeOff.create(profile_id(socket), attrs) do
      {:ok, period} ->
        saved(socket, period, dgettext("dashboard_availability_time_off", "Time off added"))

      {:error, reason} ->
        save_failed(socket, reason, data, attrs)
    end
  end

  defp saved(socket, period, message) do
    Flash.info(message)
    warn_about_bookings(TimeOff.conflicting_meetings(period))

    socket
    |> ModalHook.hide_modal(:time_off_form)
    |> load_periods()
  end

  # Said again on the way out, as a warning beside the confirmation, for the
  # host who saved without reading the panel in the form. The period is saved
  # either way: what is in the way is theirs to move, and a save that cancelled
  # meetings on their behalf would be far worse than one that said nothing.
  defp warn_about_bookings([]), do: :ok

  defp warn_about_bookings(meetings) do
    count = length(meetings)

    Flash.warning(
      dngettext(
        "dashboard_availability_time_off",
        "1 booking sits inside this time off. It stays in your diary until you move or cancel it.",
        "%{count} bookings sit inside this time off. They stay in your diary until you move or cancel them.",
        count,
        count: count
      )
    )
  end

  # The form stays open carrying what was typed, with the changeset's messages
  # under the fields they belong to; a validation failure that closed the modal
  # would discard the dates the user had just chosen.
  defp save_failed(socket, %Changeset{} = changeset, data, attrs) do
    data =
      data
      |> Map.merge(attrs)
      |> Map.put(:errors, TimeOffForm.errors(changeset))

    if map_size(data.errors) == 0 do
      Flash.error(dgettext("dashboard_availability_time_off", "Could not save your time off"))
    end

    ModalHook.show_modal(socket, :time_off_form, data)
  end

  defp save_failed(socket, :limit_reached, _data, _attrs) do
    Flash.error(
      dgettext(
        "dashboard_availability_time_off",
        "You already have the maximum of %{count} time off periods",
        count: TimeOff.max_periods()
      )
    )

    ModalHook.hide_modal(socket, :time_off_form)
  end

  defp save_failed(socket, :not_found, _data, _attrs) do
    Flash.error(dgettext("dashboard_availability_time_off", "That time off no longer exists"))

    socket
    |> ModalHook.hide_modal(:time_off_form)
    |> load_periods()
  end

  defp delete(socket, id) do
    with {:ok, period} <- TimeOff.fetch(profile_id(socket), id),
         {:ok, _deleted} <- TimeOff.delete(period) do
      Flash.info(dgettext("dashboard_availability_time_off", "Time off removed"))
    else
      _other ->
        Flash.error(dgettext("dashboard_availability_time_off", "Could not remove your time off"))
    end

    socket
    |> ModalHook.hide_modal(:delete_time_off)
    |> load_periods()
  end

  defp fetch_period(socket, id) do
    with {:ok, id} <- parse_id(id), do: TimeOff.fetch(profile_id(socket), id)
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _other -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}

  defp load_periods(socket) do
    %{current: current, past: past} = TimeOff.list_by_status(profile_id(socket))
    assign(socket, periods: current, past_periods: past)
  end

  defp profile_id(socket), do: socket.assigns.profile.id

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div>
      <.card
        icon="hero-sun"
        title={dgettext("dashboard_availability_time_off", "Time Off")}
        description={
          dgettext(
            "dashboard_availability_time_off",
            "Days you are away. These apply to every schedule and every meeting type, and nobody booking you sees why those days are closed."
          )
        }
      >
        <:actions :if={@periods != [] or @past_periods != []}>
          <%!-- An empty card carries this action in its empty state instead. --%>
          <.add_time_off_button variant={:secondary} myself={@myself} />
        </:actions>

        <%!-- The full empty state is only for a card with nothing in it at all.
             Once past periods exist, both categories show, so an empty current
             one reads as "nothing coming up" rather than disappearing above
             the past. --%>
        <.empty_state
          :if={@periods == [] and @past_periods == []}
          icon="hero-sun"
          variant={:dashed}
          title={dgettext("dashboard_availability_time_off", "No time off booked")}
          description={
            dgettext(
              "dashboard_availability_time_off",
              "Add a period and those days stop being offered, without touching your calendars."
            )
          }
          data-testid="time-off-empty"
        >
          <:action><.add_time_off_button variant={:primary} myself={@myself} /></:action>
        </.empty_state>

        <div :if={@periods != [] or @past_periods != []} data-testid="time-off-current">
          <.subsection_header
            title={dgettext("dashboard_availability_time_off", "Current and upcoming")}
            class="mb-4"
          />

          <ul :if={@periods != []} class="space-y-3" data-testid="time-off-list">
            <TimeOffPeriodRow.period_row
              :for={period <- @periods}
              period={period}
              time_format={@time_format}
              myself={@myself}
            />
          </ul>

          <.empty_state
            :if={@periods == []}
            icon="hero-sun"
            size={:sm}
            variant={:dashed}
            title={dgettext("dashboard_availability_time_off", "No upcoming time off")}
            description={
              dgettext("dashboard_availability_time_off", "Anything you add appears here.")
            }
            data-testid="time-off-current-empty"
          />
        </div>

        <div :if={@past_periods != []} class="mt-8" data-testid="time-off-past">
          <.subsection_header title={dgettext("dashboard_availability_time_off", "Past")} class="mb-2">
            <:actions>
              <.pill tone={:brand} size={:sm}>{length(@past_periods)}</.pill>
            </:actions>
          </.subsection_header>
          <p class="mb-4 text-token-sm text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_availability_time_off",
              "Time off that ended in the last %{count} days. It no longer affects your availability.",
              count: TimeOff.recent_past_days()
            )}
          </p>

          <ul class="space-y-3" data-testid="time-off-past-list">
            <TimeOffPeriodRow.period_row
              :for={period <- @past_periods}
              period={period}
              time_format={@time_format}
              myself={@myself}
              past
            />
          </ul>
        </div>

        <TimeOffFormModal.time_off_form_modal
          id="time-off-form-modal"
          show={@show_time_off_form_modal}
          period_data={@time_off_form_modal_data}
          time_format={@time_format}
          timezone={Profiles.timezone(@profile)}
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
      </.card>
    </div>
    """
  end

  attr :variant, :atom, required: true
  attr :myself, :any, required: true

  defp add_time_off_button(assigns) do
    ~H"""
    <.action_button
      variant={@variant}
      phx-click="show_time_off_form"
      phx-target={@myself}
      icon="hero-plus"
      data-testid="add-time-off"
    >
      {dgettext("dashboard_availability_time_off", "Add time off")}
    </.action_button>
    """
  end
end
