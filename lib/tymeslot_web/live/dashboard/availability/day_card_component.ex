defmodule TymeslotWeb.Dashboard.Availability.DayCardComponent do
  @moduledoc "Day card function component for the availability list view."
  use TymeslotWeb, :html

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Dashboard.Availability.ListComponent.BreakHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  attr :day_availability, :map, required: true
  attr :day_name, :string, required: true
  attr :break_duration_presets, :list, required: true
  attr :form_errors, :map, required: true
  attr :show_add_break_form, :any, required: true
  attr :myself, :any, required: true

  @spec day_card(map()) :: Phoenix.LiveView.Rendered.t()
  def day_card(assigns) do
    ~H"""
    <div class={[
      "card-glass group/day transition-all duration-300",
      if(@day_availability.is_available,
        do: "border-turquoise-100 bg-white shadow-2xl shadow-turquoise-500/5",
        else: "opacity-60 bg-tymeslot-50 border-tymeslot-100 hover:opacity-100"
      )
    ]}>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-4 gap-4">
        <div class="flex items-center gap-4">
          <div class={[
            "w-12 h-12 rounded-token-xl flex items-center justify-center font-black transition-all",
            if(@day_availability.is_available,
              do: "bg-turquoise-600 text-white shadow-lg shadow-turquoise-500/30",
              else: "bg-tymeslot-200 text-tymeslot-500"
            )
          ]}>
            {String.slice(@day_name, 0, 1)}
          </div>
          <h3 class="text-token-2xl font-black text-tymeslot-900 tracking-tight group-hover/day:text-turquoise-700 transition-colors">
            {@day_name}
          </h3>
        </div>

        <div class="flex items-center gap-4 bg-tymeslot-50 p-2 rounded-token-2xl border border-tymeslot-100">
          <button
            phx-click="toggle_day_available"
            phx-value-day={@day_availability.day_of_week}
            phx-target={@myself}
            class={[
              "relative inline-flex h-9 w-16 shrink-0 cursor-pointer rounded-full border-2 transition-all duration-300 ease-in-out focus:outline-hidden",
              if(@day_availability.is_available,
                do: "bg-turquoise-600 border-turquoise-600",
                else: "bg-tymeslot-300 border-tymeslot-300"
              )
            ]}
            role="switch"
            aria-checked={@day_availability.is_available}
          >
            <span class={[
              "pointer-events-none absolute top-1 left-1 inline-block h-7 w-7 transform rounded-full bg-white shadow-lg ring-0 transition duration-300 ease-in-out",
              if(@day_availability.is_available, do: "translate-x-7", else: "translate-x-0")
            ]}>
            </span>
          </button>
          <div class="w-24 text-left">
            <span class={[
              "text-token-sm font-black uppercase tracking-wider",
              if(@day_availability.is_available, do: "text-turquoise-700", else: "text-tymeslot-400")
            ]}>
              {if @day_availability.is_available, do: "Available", else: "Off"}
            </span>
          </div>
        </div>
      </div>

      <%= if @day_availability.is_available do %>
        <%!-- Work Hours --%>
        <div class="mb-6 pb-6 border-b-2 border-tymeslot-50">
          <form id={"day-hours-form-#{@day_availability.day_of_week}"} phx-change="update_day_hours" phx-target={@myself} phx-debounce="500">
            <input type="hidden" name="day" value={@day_availability.day_of_week} />
            <div class="flex flex-col sm:flex-row sm:items-center gap-6">
              <div class="flex-1">
                <.input
                  type="select"
                  name="start"
                  label="Start Time"
                  options={TimeOptions.time_options()}
                  value={BreakHelpers.format_time(@day_availability.start_time)}
                />
              </div>
              <div class="flex-1">
                <.input
                  type="select"
                  name="end"
                  label="End Time"
                  options={TimeOptions.time_options()}
                  value={BreakHelpers.format_time(@day_availability.end_time)}
                />
              </div>
            </div>
          </form>
        </div>

        <%!-- Breaks --%>
        <div class="space-y-4">
          <div class="flex items-center justify-between gap-3">
            <div class="flex items-center gap-3">
              <h4 class="text-token-lg font-black text-tymeslot-900 tracking-tight">Breaks</h4>
              <% breaks =
                case @day_availability.breaks do
                  %Ecto.Association.NotLoaded{} -> []
                  b when is_list(b) -> b
                  _other -> []
                end %>
              <span class="bg-tymeslot-100 text-tymeslot-500 text-token-2xs font-black uppercase tracking-widest px-2 py-0.5 rounded-md">
                {length(breaks)} total
              </span>
            </div>

            <%= if @show_add_break_form != @day_availability.day_of_week do %>
              <button
                phx-click="show_add_break_form"
                phx-value-day={@day_availability.day_of_week}
                phx-target={@myself}
                class="btn-secondary py-2 px-3 text-token-xs flex items-center whitespace-nowrap"
              >
                <svg class="w-3.5 h-3.5 mr-1.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 4v16m8-8H4" />
                </svg>
                Add Break
              </button>
            <% end %>
          </div>

          <%= if breaks != [] do %>
            <div class="flex flex-wrap gap-3">
              <%= for break <- breaks do %>
                <div class="inline-flex items-center bg-white border-2 border-tymeslot-100 rounded-token-xl px-4 py-2 text-token-sm font-bold text-tymeslot-700 shadow-sm group/break hover:border-turquoise-200 transition-all">
                  <span class="mr-3">{break.label || "Break"}</span>
                  <span class="text-turquoise-600">
                    {BreakHelpers.format_time(break.start_time)} - {BreakHelpers.format_time(break.end_time)}
                  </span>
                  <button
                    phx-click="show_delete_break_modal"
                    phx-value-break_id={break.id}
                    phx-target={@myself}
                    class="ml-3 text-tymeslot-300 hover:text-red-500 transition-colors"
                    title="Delete Break"
                  >
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Add Break Form --%>
          <%= if @show_add_break_form == @day_availability.day_of_week do %>
            <form
              id={"add-break-form-#{@day_availability.day_of_week}"}
              phx-submit="add_break"
              phx-change="validate_break"
              phx-target={@myself}
              class="grid grid-cols-1 lg:grid-cols-4 gap-4 items-end bg-tymeslot-50/50 p-4 rounded-token-2xl border-2 border-tymeslot-50"
            >
              <input type="hidden" name="day" value={@day_availability.day_of_week} />
              <div class="lg:col-span-1">
                <.input
                  name="label"
                  label="Label"
                  placeholder="e.g. Lunch"
                  maxlength={Constraints.break_label_max_length()}
                  errors={FormValidationHelpers.field_errors(@form_errors, :label)}
                />
              </div>
              <div>
                <.input
                  type="select"
                  name="start"
                  label="From"
                  required
                  prompt="Start"
                  options={TimeOptions.time_options()}
                  errors={FormValidationHelpers.field_errors(@form_errors, :start_time)}
                />
              </div>
              <div>
                <.input
                  type="select"
                  name="end"
                  label="Until"
                  required
                  prompt="End"
                  options={TimeOptions.time_options()}
                  errors={FormValidationHelpers.field_errors(@form_errors, :end_time)}
                />
              </div>
              <div class="flex gap-2">
                <button type="submit" class="btn-primary flex-1 py-3 flex items-center justify-center whitespace-nowrap">
                  <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 4v16m8-8H4" />
                  </svg>
                  Add
                </button>
                <button
                  type="button"
                  phx-click="hide_add_break_form"
                  phx-target={@myself}
                  class="btn-secondary px-3 py-3"
                  title="Cancel"
                >
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>
            </form>
          <% end %>
        </div>

        <%!-- Action Bar --%>
        <div class="flex flex-wrap items-center justify-between gap-4 mt-6 pt-6 border-t-2 border-tymeslot-50">
          <div class="flex flex-wrap gap-3">
            <button
              phx-click="copy_to_days"
              phx-value-from_day={@day_availability.day_of_week}
              phx-value-to_days="1,2,3,4,5,6,7"
              phx-target={@myself}
              class="btn-secondary py-2 px-4 text-token-xs flex items-center whitespace-nowrap"
            >
              <svg class="w-3.5 h-3.5 mr-2 text-tymeslot-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4" />
              </svg>
              Apply to All Days
            </button>
            <button
              phx-click="copy_to_days"
              phx-value-from_day={@day_availability.day_of_week}
              phx-value-to_days="1,2,3,4,5"
              phx-target={@myself}
              class="btn-secondary py-2 px-4 text-token-xs flex items-center whitespace-nowrap"
            >
              <svg class="w-3.5 h-3.5 mr-2 text-tymeslot-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4" />
              </svg>
              Apply to Workdays
            </button>
          </div>
          <button
            phx-click="show_clear_day_modal"
            phx-value-day={@day_availability.day_of_week}
            phx-target={@myself}
            class="text-tymeslot-400 hover:text-red-600 text-token-xs font-black uppercase tracking-widest flex items-center gap-2 transition-colors"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
            </svg>
            Clear Day
          </button>
        </div>
      <% else %>
        <div class="py-4 px-6 bg-tymeslot-50 rounded-token-2xl border-2 border-dashed border-tymeslot-100">
          <p class="text-tymeslot-400 font-bold text-token-sm">Not taking any bookings on this day.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
