defmodule TymeslotWeb.Components.Dashboard.Availability.TimeOffFormModal do
  @moduledoc """
  Modal for adding or editing a time-off period.

  One form serves both, because a period is the same shape either way: a date
  range, optionally trimmed at each end by a time, plus a private label.

  The two time pickers default to "All day", so the common case — a holiday
  measured in whole days — is the one that needs no input. They are labelled by
  the day they act on rather than as a generic start and end, since on a
  multi-day period the first time applies to the first day and the second to
  the last, and a plain "from/to" pair reads as if both applied to every day
  in between.
  """

  use Phoenix.Component
  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  # How many of the bookings inside the period the panel names before it
  # counts the rest. A fortnight away can hold dozens, and a list that long
  # pushes the form's own fields off the screen.
  @bookings_listed 5

  @doc """
  Renders the add/edit time-off form.

  `period_data` carries `:mode` (`:create` or `:edit`), the current field
  values as strings, `:errors`, a map of field to message rendered under the
  field it belongs to, `:min_starts_on`/`:min_ends_on` and
  `:max_starts_on`/`:max_ends_on`, the earliest and latest date each picker
  offers, and `:conflicts`, the bookings that already sit inside the dates as
  they currently stand.

  The bounds are a hint, not a guard: a typed or pasted date outside them
  still posts, and the changeset is what refuses it. They are here so the
  picker stops a mistyped year before the rest of the form has been filled
  in.
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :period_data, :map, default: nil
  attr :time_format, :string, default: "24h"
  attr :timezone, :string, default: nil
  attr :on_cancel, JS, required: true
  attr :myself, :any, required: true

  @spec time_off_form_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def time_off_form_modal(assigns) do
    conflicts = conflicts(assigns.period_data)

    assigns =
      assign(assigns,
        conflict_count: length(conflicts),
        listed_conflicts: Enum.take(conflicts, @bookings_listed),
        unlisted_conflicts: max(length(conflicts) - @bookings_listed, 0)
      )

    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <CoreComponents.icon name="hero-sun" class="w-5 h-5 text-turquoise-500" />
          {header_title(@period_data)}
        </div>
      </:header>

      <form
        :if={@period_data}
        id={"#{@id}-form"}
        phx-change="validate_time_off"
        phx-submit="save_time_off"
        phx-target={@myself}
      >
        <div class="space-y-6">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <CoreComponents.input
              type="date"
              id={"#{@id}-starts-on"}
              name="starts_on"
              value={Map.get(@period_data, :starts_on, "")}
              min={Map.get(@period_data, :min_starts_on)}
              max={Map.get(@period_data, :max_starts_on)}
              label={dgettext("dashboard_availability", "First day away")}
              errors={field_errors(@period_data, :starts_on)}
            />
            <CoreComponents.input
              type="date"
              id={"#{@id}-ends-on"}
              name="ends_on"
              value={Map.get(@period_data, :ends_on, "")}
              min={Map.get(@period_data, :min_ends_on)}
              max={Map.get(@period_data, :max_ends_on)}
              label={dgettext("dashboard_availability", "Last day away")}
              errors={field_errors(@period_data, :ends_on)}
            />
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <CoreComponents.input
              type="select"
              id={"#{@id}-start-time"}
              name="start_time"
              value={Map.get(@period_data, :start_time, "")}
              options={all_day_options(@time_format)}
              label={dgettext("dashboard_availability", "Away from (first day)")}
              errors={field_errors(@period_data, :start_time)}
            />
            <CoreComponents.input
              type="select"
              id={"#{@id}-end-time"}
              name="end_time"
              value={Map.get(@period_data, :end_time, "")}
              options={all_day_options(@time_format)}
              label={dgettext("dashboard_availability", "Back at (last day)")}
              errors={field_errors(@period_data, :end_time)}
            />
          </div>

          <p class="text-token-sm text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_availability",
              "Any day between the first and the last is blocked in full."
            )}
          </p>

          <%!-- Time off closes the days to new bookings and leaves the ones
          already taken exactly where they are, so the host has to be told what
          they are about to leave behind. Saving is never in the way of it. --%>
          <div
            :if={@conflict_count > 0}
            class="flex items-start gap-3 rounded-token-xl border-2 border-amber-200 bg-amber-50 px-4 py-4"
            data-testid="time-off-conflicts"
          >
            <CoreComponents.icon
              name="hero-exclamation-triangle"
              class="w-5 h-5 shrink-0 text-amber-600"
            />

            <div class="min-w-0">
              <p class="font-bold text-amber-800">
                {dngettext(
                  "dashboard_availability",
                  "1 booking already sits inside these dates",
                  "%{count} bookings already sit inside these dates",
                  @conflict_count,
                  count: @conflict_count
                )}
              </p>
              <p class="mt-1 text-token-sm font-medium text-amber-700">
                {dgettext(
                  "dashboard_availability",
                  "Time off only stops new bookings. These keep their times until you move or cancel them."
                )}
              </p>

              <ul class="mt-3 space-y-1 text-token-sm text-amber-800">
                <li :for={meeting <- @listed_conflicts} class="truncate">
                  <span class="font-bold">
                    {LocalizationHelpers.format_meeting_datetime_compact(
                      meeting.start_time,
                      @timezone
                    )}
                  </span>
                  <span class="font-medium">{meeting.title}</span>
                </li>
                <li :if={@unlisted_conflicts > 0} class="font-medium">
                  {dngettext(
                    "dashboard_availability",
                    "and 1 more",
                    "and %{count} more",
                    @unlisted_conflicts,
                    count: @unlisted_conflicts
                  )}
                </li>
              </ul>

              <.link
                href={~p"/dashboard/meetings"}
                target="_blank"
                rel="noopener"
                class="inline-block mt-3 text-token-sm font-bold text-amber-800 underline underline-offset-2 hover:text-amber-900"
              >
                {dgettext("dashboard_availability", "Open your bookings in a new tab")}
              </.link>
            </div>
          </div>

          <CoreComponents.input
            type="text"
            id={"#{@id}-label"}
            name="label"
            value={Map.get(@period_data, :label, "")}
            maxlength={Constraints.time_off_label_max_length()}
            phx-debounce="300"
            label={dgettext("dashboard_availability", "Note (only you see this)")}
            placeholder={dgettext("dashboard_availability", "Holiday")}
            errors={field_errors(@period_data, :label)}
          />
        </div>

        <div class="flex justify-end gap-3 mt-8">
          <CoreComponents.action_button variant={:secondary} type="button" phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button variant={:primary} type="submit">
            {dgettext("dashboard_availability", "Save")}
          </CoreComponents.action_button>
        </div>
      </form>
    </CoreComponents.modal>
    """
  end

  defp header_title(%{mode: :edit}), do: dgettext("dashboard_availability", "Edit time off")
  defp header_title(_create), do: dgettext("dashboard_availability", "Add time off")

  # The modal renders with no data at all before it has first been opened.
  defp conflicts(nil), do: []
  defp conflicts(period_data), do: Map.get(period_data, :conflicts, [])

  defp field_errors(period_data, field) do
    case period_data |> Map.get(:errors, %{}) |> Map.get(field) do
      nil -> []
      message -> [message]
    end
  end

  # "All day" is the empty value the schema reads as nil, so the default choice
  # produces a whole-day period without the form having to special-case it.
  defp all_day_options(time_format) do
    [{dgettext("dashboard_availability", "All day"), ""} | TimeOptions.time_options(time_format)]
  end
end
