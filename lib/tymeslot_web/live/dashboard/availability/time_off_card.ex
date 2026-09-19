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
  alias Tymeslot.Validation.Constraints

  alias TymeslotWeb.Components.Dashboard.Availability.{DeleteTimeOffModal, TimeOffFormModal}
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  # Fields the form renders an inline error under. Anything else the changeset
  # can complain about has no home in the form and becomes a flash instead.
  @form_fields [:starts_on, :ends_on, :start_time, :end_time, :label]

  # The fields that decide which bookings the period swallows. The note does
  # not, so typing one must not send the overlap query off again.
  @schedule_fields [:starts_on, :ends_on, :start_time, :end_time]

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
           edit_data(period, TimeOff.today(socket.assigns.profile.timezone))
         )}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_availability", "That time off no longer exists"))
        {:noreply, load_periods(socket)}
    end
  end

  def handle_event("show_time_off_form", _params, socket) do
    if TimeOff.can_create?(profile_id(socket)) do
      {:noreply,
       ModalHook.show_modal(
         socket,
         :time_off_form,
         blank_data(TimeOff.today(socket.assigns.profile.timezone))
       )}
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

  # Runs the same rules as saving, on every change, so a date in the past or a
  # backwards range is flagged beside its field before the form is submitted.
  def handle_event("validate_time_off", params, socket) do
    ModalHook.with_modal_data(socket, :time_off_form, fn data ->
      {:noreply,
       ModalHook.show_modal(
         socket,
         :time_off_form,
         validated_data(socket, data, attrs_from(params))
       )}
    end)
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

  # A finished period is removed in place, without the confirmation dialog: it
  # no longer affects availability, so there is nothing for the dialog to
  # protect. The row crosses itself out and fades on the client; the check here
  # keeps a period that has not ended from being removed this way.
  def handle_event("delete_past_time_off", %{"id" => id}, socket) do
    today = TimeOff.today(socket.assigns.profile.timezone)

    with {:ok, period} <- fetch_period(socket, id),
         true <- TimeOff.ended?(period, today),
         {:ok, _deleted} <- TimeOff.delete(period) do
      :ok
    else
      _other -> Flash.error(dgettext("dashboard_availability", "Could not remove your time off"))
    end

    {:noreply, load_periods(socket)}
  end

  defp save(socket, %{mode: :edit, id: id} = data, attrs) do
    with {:ok, period} <- TimeOff.fetch(profile_id(socket), id),
         {:ok, updated} <- TimeOff.update(period, attrs) do
      saved(socket, updated, dgettext("dashboard_availability", "Time off updated"))
    else
      {:error, reason} -> save_failed(socket, reason, data, attrs)
    end
  end

  defp save(socket, data, attrs) do
    case TimeOff.create(profile_id(socket), attrs) do
      {:ok, period} ->
        saved(socket, period, dgettext("dashboard_availability", "Time off added"))

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
        "dashboard_availability",
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
      |> Map.put(:errors, form_errors(changeset))

    if map_size(data.errors) == 0 do
      Flash.error(dgettext("dashboard_availability", "Could not save your time off"))
    end

    ModalHook.show_modal(socket, :time_off_form, data)
  end

  defp save_failed(socket, :limit_reached, _data, _attrs) do
    Flash.error(
      dgettext(
        "dashboard_availability",
        "You already have the maximum of %{count} time off periods",
        count: TimeOff.max_periods()
      )
    )

    ModalHook.hide_modal(socket, :time_off_form)
  end

  defp save_failed(socket, :not_found, _data, _attrs) do
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

  # Only fields that hold a value report while the form is being filled in: a
  # last day not chosen yet is not an error until the form is submitted.
  #
  # The rules themselves read nothing from the database: the period being
  # edited was loaded when the form opened, and today comes from the profile
  # already assigned. Saving re-reads both. Only the overlap panel below costs
  # a query, and only when a date or a time has moved.
  defp validated_data(socket, data, attrs) do
    changeset =
      data
      |> validation_target(socket)
      |> TimeOff.validate(attrs, today: TimeOff.today(socket.assigns.profile.timezone))

    errors =
      changeset
      |> form_errors()
      |> Map.reject(fn {field, _message} -> Map.fetch!(attrs, field) == "" end)

    data
    |> Map.merge(attrs)
    |> Map.put(:errors, errors)
    |> Map.put(:conflicts, conflicts(data, attrs, changeset))
  end

  # The bookings already inside the period, so the modal can name them while
  # the dates are still being chosen rather than only once the row is written.
  # Reading them is a query, so it runs only when a date or a time actually
  # moved: every other change leaves the answer as it was.
  defp conflicts(data, attrs, changeset) do
    if Map.take(data, @schedule_fields) == Map.take(attrs, @schedule_fields) do
      Map.get(data, :conflicts, [])
    else
      TimeOff.conflicting_meetings(changeset)
    end
  end

  defp validation_target(%{mode: :edit, period: period}, _socket), do: period
  defp validation_target(_create, socket), do: profile_id(socket)

  defp fetch_period(socket, id) when is_integer(id), do: TimeOff.fetch(profile_id(socket), id)

  defp fetch_period(socket, id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> fetch_period(socket, parsed)
      _other -> {:error, :not_found}
    end
  end

  defp fetch_period(_socket, _id), do: {:error, :not_found}

  defp load_periods(socket) do
    %{current: current, past: past} = TimeOff.list_by_status(profile_id(socket))
    assign(socket, periods: current, past_periods: past)
  end

  defp profile_id(socket), do: socket.assigns.profile.id

  # Anything but a string, which only a hand-built event can send, reads as
  # blank rather than crashing the component.
  defp attrs_from(params) do
    Map.new(@form_fields, fn field ->
      case Map.get(params, to_string(field)) do
        value when is_binary(value) -> {field, String.trim(value)}
        _missing_or_malformed -> {field, ""}
      end
    end)
  end

  # The `min_*` dates keep the date pickers from offering days already gone,
  # and the `max_*` ones the years a mistyped date lands in. On an edit both
  # reach out to the stored date when it falls outside them, or the browser
  # would refuse to submit a period already under way, or one already reaching
  # further ahead than the bound allows, at all.
  defp blank_data(today) do
    last_day = today |> Constraints.time_off_last_end_date() |> Date.to_iso8601()

    @form_fields
    |> Map.new(&{&1, ""})
    |> Map.merge(%{
      mode: :create,
      id: nil,
      errors: %{},
      conflicts: [],
      min_starts_on: Date.to_iso8601(today),
      min_ends_on: Date.to_iso8601(today),
      max_starts_on: last_day,
      max_ends_on: last_day
    })
  end

  # A stored period is read for overlaps as the form opens: an edit is the
  # likelier way to swallow a booking, because the row is one the host already
  # trusts, and the panel has to be there before anything is changed.
  defp edit_data(period, today) do
    last_end_date = Constraints.time_off_last_end_date(today)

    %{
      mode: :edit,
      id: period.id,
      period: period,
      errors: %{},
      conflicts: TimeOff.conflicting_meetings(period),
      min_starts_on: earliest_iso8601(period.starts_on, today),
      min_ends_on: earliest_iso8601(period.ends_on, today),
      max_starts_on: latest_iso8601(period.starts_on, last_end_date),
      max_ends_on: latest_iso8601(period.ends_on, last_end_date),
      starts_on: Date.to_iso8601(period.starts_on),
      ends_on: Date.to_iso8601(period.ends_on),
      start_time: wire_time(period.start_time),
      end_time: wire_time(period.end_time),
      label: period.label || ""
    }
  end

  defp earliest_iso8601(date, today), do: [date, today] |> Enum.min(Date) |> Date.to_iso8601()

  defp latest_iso8601(date, bound), do: [date, bound] |> Enum.max(Date) |> Date.to_iso8601()

  # Kept as `{message, opts}` rather than flattened to a string: the form input
  # translates that shape through the `errors` domain, interpolating counts, in
  # whatever language the dashboard is in.
  defp form_errors(changeset) do
    changeset
    |> Changeset.traverse_errors(& &1)
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

      <%!-- The full empty state is only for a card with nothing in it at all.
      Once past periods exist, both categories show, so an empty current one
      reads as "nothing coming up" rather than disappearing above the past. --%>
      <.empty_state
        :if={@periods == [] and @past_periods == []}
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

      <div :if={@periods != [] or @past_periods != []} data-testid="time-off-current">
        <.section_header
          level={4}
          title={dgettext("dashboard_availability", "Current and upcoming")}
          class="mb-4"
        />

        <ul :if={@periods != []} class="space-y-3" data-testid="time-off-list">
          <.period_row
            :for={period <- @periods}
            period={period}
            time_format={@time_format}
            myself={@myself}
          />
        </ul>

        <div
          :if={@periods == []}
          class="flex items-center gap-3 rounded-token-xl border-2 border-dashed border-tymeslot-200 px-4 py-4 text-token-sm font-medium text-tymeslot-500"
          data-testid="time-off-current-empty"
        >
          <.icon name="hero-sun" class="w-5 h-5 shrink-0 text-tymeslot-300" />
          {dgettext("dashboard_availability", "No upcoming time off. Anything you add appears here.")}
        </div>
      </div>

      <div :if={@past_periods != []} class="mt-8" data-testid="time-off-past">
        <.section_header
          level={4}
          title={dgettext("dashboard_availability", "Past")}
          count={length(@past_periods)}
          class="mb-2"
        />
        <p class="mb-4 text-token-sm text-tymeslot-500 font-medium">
          {dgettext(
            "dashboard_availability",
            "Time off that ended in the last %{count} days. It no longer affects your availability.",
            count: TimeOff.recent_past_days()
          )}
        </p>

        <ul class="space-y-3" data-testid="time-off-past-list">
          <.period_row
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
        timezone={@profile.timezone}
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

  attr :period, :any, required: true
  attr :time_format, :string, required: true
  attr :myself, :any, required: true
  attr :past, :boolean, default: false

  # A finished period has no edit button: there is nothing left to move, since
  # neither of its dates may be placed in the past again.
  defp period_row(assigns) do
    ~H"""
    <li
      id={row_id(@period, @past)}
      phx-remove={@past && row_removal()}
      class={[
        "flex flex-wrap items-center justify-between gap-3 rounded-token-xl border border-tymeslot-100 px-4 py-3",
        if(@past, do: "bg-white", else: "bg-tymeslot-50")
      ]}
    >
      <div class="min-w-0" data-strike>
        <p class={["font-bold", if(@past, do: "text-tymeslot-500", else: "text-tymeslot-700")]}>
          {range_summary(@period, @time_format)}
        </p>
        <p :if={@period.label} class="text-token-sm text-tymeslot-500 font-medium truncate">
          {@period.label}
        </p>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <button
          :if={not @past}
          type="button"
          phx-click="show_time_off_form"
          phx-value-id={@period.id}
          phx-target={@myself}
          class="flex items-center justify-center h-9 w-9 bg-white text-tymeslot-700 rounded-token-lg border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
          aria-label={dgettext("dashboard_availability", "Edit time off")}
        >
          <.icon name="hero-pencil-square" class="w-5 h-5" />
        </button>
        <button
          type="button"
          phx-click={
            if @past,
              do: remove_past(@period, @myself),
              else: JS.push("show_delete_time_off", value: %{id: @period.id}, target: @myself)
          }
          class="flex items-center justify-center h-9 w-9 text-tymeslot-500 hover:text-red-500 hover:bg-red-50 rounded-token-lg border-2 border-transparent hover:border-red-100 transition-all"
          aria-label={dgettext("dashboard_availability", "Remove time off")}
        >
          <.icon name="hero-trash" class="w-5 h-5" />
        </button>
      </div>
    </li>
    """
  end

  defp row_id(period, true), do: "time-off-past-#{period.id}"
  defp row_id(period, false), do: "time-off-#{period.id}"

  # Crossed out at once, then removed by the server: the row's `phx-remove`
  # fades it once the re-render drops it, after a short pause so the line
  # through it registers first.
  defp remove_past(period, myself) do
    row = "#" <> row_id(period, true)

    "line-through decoration-2 decoration-tymeslot-400"
    |> JS.add_class(to: "#{row} [data-strike]")
    |> JS.add_class("pointer-events-none", to: row)
    |> JS.push("delete_past_time_off", value: %{id: period.id}, target: myself)
  end

  defp row_removal do
    JS.hide(
      transition:
        {"transition-all duration-700 delay-500 ease-in", "opacity-100 translate-x-0",
         "opacity-0 translate-x-6"},
      time: 1200
    )
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
