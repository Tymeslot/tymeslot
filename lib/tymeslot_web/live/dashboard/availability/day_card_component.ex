defmodule TymeslotWeb.Dashboard.Availability.DayCardComponent do
  @moduledoc """
  One row per weekday in the availability editor.

  Seven days share this surface, so each one is a single line: toggle, name,
  the two hour selects, and its breaks as inline chips. The bulk actions that
  used to sit in a per-day footer (copy to other days, clear the day) live in a
  small menu instead, because they are occasional and were costing every day a
  permanent two-button bar.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Dashboard.Availability.ListComponent.BreakHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  attr :day_availability, :map, required: true
  attr :day_name, :string, required: true
  attr :break_duration_presets, :list, required: true
  attr :form_errors, :map, required: true
  attr :show_add_break_form, :any, required: true
  attr :open_menu_day, :any, required: true
  attr :time_format, :string, required: true
  attr :myself, :any, required: true

  @spec day_card(map()) :: Phoenix.LiveView.Rendered.t()
  def day_card(assigns) do
    assigns =
      assigns
      |> assign(:day, assigns.day_availability.day_of_week)
      |> assign(:breaks, breaks_of(assigns.day_availability))
      |> assign(:break_times, break_times(assigns.day_availability, assigns.time_format))

    ~H"""
    <div class={[
      "rounded-token-xl border-2 transition-colors duration-200",
      if(@day_availability.is_available,
        do: "border-tymeslot-100 bg-white",
        else: "border-transparent bg-white/40"
      )
    ]}>
      <div class="flex flex-wrap items-center gap-x-4 gap-y-3 px-4 py-3">
        <button
          phx-click="toggle_day_available"
          phx-value-day={@day}
          phx-target={@myself}
          class={[
            "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 transition-colors duration-200 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400",
            if(@day_availability.is_available,
              do: "bg-turquoise-600 border-turquoise-600",
              else: "bg-tymeslot-300 border-tymeslot-300"
            )
          ]}
          role="switch"
          aria-checked={to_string(@day_availability.is_available)}
          aria-label={toggle_label(@day_availability.is_available, @day_name)}
        >
          <span class={[
            "pointer-events-none absolute top-0.5 left-0.5 inline-block h-4 w-4 rounded-full bg-white shadow transition-transform duration-200",
            if(@day_availability.is_available, do: "translate-x-5", else: "translate-x-0")
          ]}></span>
        </button>

        <span class={[
          "w-24 shrink-0 font-bold text-token-sm",
          if(@day_availability.is_available,
            do: "text-tymeslot-900",
            else: "text-tymeslot-400"
          )
        ]}>
          {@day_name}
        </span>

        <%= if @day_availability.is_available do %>
          <form
            id={"day-hours-form-#{@day}"}
            phx-change="update_day_hours"
            phx-target={@myself}
            phx-debounce="500"
            class="day-hours-inline flex items-center gap-2 shrink-0"
          >
            <input type="hidden" name="day" value={@day} />
            <.input
              type="select"
              name="start"
              options={TimeOptions.time_options(@time_format)}
              value={BreakHelpers.format_time(@day_availability.start_time)}
              aria-label={dgettext("dashboard_availability", "Start Time")}
            />
            <span class="text-tymeslot-400">–</span>
            <.input
              type="select"
              name="end"
              options={TimeOptions.time_options(@time_format)}
              value={BreakHelpers.format_time(@day_availability.end_time)}
              aria-label={dgettext("dashboard_availability", "End Time")}
            />
          </form>

          <div class="flex flex-wrap items-center gap-2 grow">
            <span
              :for={break <- @breaks}
              class="inline-flex items-center gap-2 rounded-token-lg bg-tymeslot-50 border border-tymeslot-100 px-2 py-1 text-token-xs font-bold text-tymeslot-600"
            >
              {break.label || dgettext("dashboard_availability", "Break")}
              <span class="text-turquoise-600 font-medium">
                {TimeFormat.format(break.start_time, @time_format)} - {TimeFormat.format(
                  break.end_time,
                  @time_format
                )}
              </span>
              <button
                phx-click="show_delete_break_modal"
                phx-value-break_id={break.id}
                phx-target={@myself}
                class="text-tymeslot-300 hover:text-red-500 transition-colors"
                aria-label={dgettext("dashboard_availability", "Delete Break")}
              >
                <.icon name="hero-x-mark-micro" class="w-3.5 h-3.5" />
              </button>
            </span>

            <button
              :if={@show_add_break_form != @day}
              phx-click="show_add_break_form"
              phx-value-day={@day}
              phx-target={@myself}
              class="inline-flex items-center gap-1 rounded-token-lg px-2 py-1 text-token-xs font-bold text-tymeslot-400 hover:text-turquoise-700 hover:bg-turquoise-50 transition-colors"
            >
              <.icon name="hero-plus-micro" class="w-3.5 h-3.5" />
              {dgettext("dashboard_availability", "Add Break")}
            </button>
          </div>

          <.dropdown
            id={"day-actions-#{@day}"}
            open={@open_menu_day == @day}
            on_toggle="toggle_day_menu"
            on_close="close_day_menu"
            target={@myself}
            trigger_class="flex items-center justify-center w-8 h-8 shrink-0 rounded-token-lg text-tymeslot-400 hover:bg-tymeslot-50 hover:text-turquoise-700 transition-colors focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            trigger_attrs={[{"phx-value-day", @day}]}
            class="bg-white border-2 border-tymeslot-100 rounded-token-xl shadow-lg py-1 w-56"
            aria-label={day_menu_label(@day_name)}
          >
            <:trigger>
              <.icon name="hero-ellipsis-horizontal" class="w-4 h-4" />
            </:trigger>
            <:panel>
              <.dropdown_item
                label={dgettext("dashboard_availability", "Apply to All Days")}
                icon="hero-arrows-right-left"
                phx-click="copy_to_days"
                phx-value-from_day={@day}
                phx-value-to_days="1,2,3,4,5,6,7"
                phx-target={@myself}
              />
              <.dropdown_item
                label={dgettext("dashboard_availability", "Apply to Workdays")}
                icon="hero-arrows-right-left"
                phx-click="copy_to_days"
                phx-value-from_day={@day}
                phx-value-to_days="1,2,3,4,5"
                phx-target={@myself}
              />
              <.dropdown_divider />
              <.dropdown_item
                label={dgettext("dashboard_availability", "Clear Day")}
                icon="hero-trash"
                danger
                phx-click="show_clear_day_modal"
                phx-value-day={@day}
                phx-target={@myself}
              />
            </:panel>
          </.dropdown>
        <% else %>
          <span class="text-token-sm text-tymeslot-400 font-medium">
            {dgettext("dashboard_availability", "Unavailable")}
          </span>
        <% end %>
      </div>

      <%!-- The add-break form drops below its day rather than inline, so the
      row keeps its height until the user asks for it. Fields are top-aligned:
      bottom-aligning them lets a validation message under one field push every
      other field out of line as it appears. --%>
      <form
        :if={@show_add_break_form == @day}
        id={"add-break-form-#{@day}"}
        phx-submit="add_break"
        phx-change="validate_break"
        phx-target={@myself}
        class="flex flex-wrap items-start gap-3 border-t-2 border-tymeslot-50 bg-tymeslot-50/40 px-4 py-3"
      >
        <input type="hidden" name="day" value={@day} />
        <div class="w-40">
          <.input
            name="label"
            label={dgettext("dashboard_availability", "Label")}
            placeholder={dgettext("dashboard_availability", "e.g. Lunch")}
            maxlength={Constraints.break_label_max_length()}
            errors={FormValidationHelpers.field_errors(@form_errors, :label)}
          />
        </div>
        <div class="w-32">
          <.input
            type="select"
            name="start"
            label={dgettext("dashboard_availability", "From")}
            required
            prompt={dgettext("dashboard_availability", "Start")}
            options={@break_times.start}
            errors={FormValidationHelpers.field_errors(@form_errors, :start_time)}
          />
        </div>
        <div class="w-32">
          <.input
            type="select"
            name="end"
            label={dgettext("dashboard_availability", "Until")}
            required
            prompt={dgettext("dashboard_availability", "End")}
            options={@break_times.end}
            errors={FormValidationHelpers.field_errors(@form_errors, :end_time)}
          />
        </div>
        <div>
          <%!-- Empty label of the same shape as the fields', so the buttons sit
          on the input line without hard-coding the label's height. --%>
          <span class="label" aria-hidden="true">&nbsp;</span>
          <div class="flex gap-2">
            <button type="submit" class="btn-primary py-3 px-4 text-token-sm whitespace-nowrap">
              {dgettext("dashboard_availability", "Add")}
            </button>
            <button
              type="button"
              phx-click="hide_add_break_form"
              phx-target={@myself}
              class="btn-secondary py-3 px-3"
              aria-label={dgettext("dashboard_availability", "Cancel")}
            >
              <.icon name="hero-x-mark-mini" class="w-4 h-4" />
            </button>
          </div>
        </div>
      </form>
    </div>
    """
  end

  defp breaks_of(%{breaks: breaks}) when is_list(breaks), do: breaks
  defp breaks_of(_day_availability), do: []

  # A break lives inside its day, so the pickers only offer that window: the
  # "from" list stops one slot short of the day's end and the "until" list
  # starts one slot after its beginning, which leaves ordering as the only way
  # left to pick an invalid pair.
  defp break_times(%{start_time: %Time{} = from, end_time: %Time{} = to}, time_format) do
    slots = TimeOptions.time_options_between(from, to, time_format)

    %{start: Enum.drop(slots, -1), end: Enum.drop(slots, 1)}
  end

  defp break_times(_day_availability, _time_format), do: %{start: [], end: []}

  defp toggle_label(true, day_name),
    do: dgettext("dashboard_availability", "Stop taking bookings on %{day}", day: day_name)

  defp toggle_label(false, day_name),
    do: dgettext("dashboard_availability", "Take bookings on %{day}", day: day_name)

  defp day_menu_label(day_name),
    do: dgettext("dashboard_availability", "More actions for %{day}", day: day_name)
end
