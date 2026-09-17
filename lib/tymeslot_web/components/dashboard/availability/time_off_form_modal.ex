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
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Shared.TimeOptions

  @doc """
  Renders the add/edit time-off form.

  `period_data` carries `:mode` (`:create` or `:edit`), the current field
  values as strings, `:errors`, a map of field to message rendered under the
  field it belongs to, and `:min_starts_on`/`:min_ends_on`, the earliest date
  each picker offers.
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :period_data, :map, default: nil
  attr :time_format, :string, default: "24h"
  attr :on_cancel, JS, required: true
  attr :myself, :any, required: true

  @spec time_off_form_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def time_off_form_modal(assigns) do
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
              label={dgettext("dashboard_availability", "First day away")}
              errors={field_errors(@period_data, :starts_on)}
            />
            <CoreComponents.input
              type="date"
              id={"#{@id}-ends-on"}
              name="ends_on"
              value={Map.get(@period_data, :ends_on, "")}
              min={Map.get(@period_data, :min_ends_on)}
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
