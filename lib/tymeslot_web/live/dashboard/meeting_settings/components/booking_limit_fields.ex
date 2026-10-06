defmodule TymeslotWeb.Dashboard.MeetingSettings.Components.BookingLimitFields do
  @moduledoc """
  The three booking caps, per day, week and month, as one row of number
  inputs. An empty field means no limit.

  Shared by the account-wide limits on the meeting types page and a single
  meeting type's limits in its form, which differ only in where the values come
  from, how the inputs are named and how a change is sent: `as` nests the names
  under a form's param key, and any further attributes (`phx-change`,
  `phx-debounce`, `phx-target`) go to every input.

  The heading above the row is what names the group, so `labelledby` takes its
  id.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints

  attr :id, :string, required: true, doc: "Prefix of the inputs' ids"
  attr :day, :any, default: nil, doc: "The current cap per day, nil for none"
  attr :week, :any, default: nil, doc: "The current cap per week, nil for none"
  attr :month, :any, default: nil, doc: "The current cap per month, nil for none"
  attr :as, :string, default: nil, doc: "Nests each input's name under this param key"
  attr :labelledby, :string, default: nil, doc: "The id of the heading that names the group"
  attr :rest, :global, doc: "Attributes for every input (`phx-change`, `phx-target`, …)"

  @spec booking_limit_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_limit_fields(assigns) do
    assigns =
      assign(assigns,
        fields:
          Enum.zip([
            Constraints.booking_limit_fields(),
            [assigns.day, assigns.week, assigns.month],
            labels()
          ]),
        range: Constraints.booking_limit_range()
      )

    ~H"""
    <div role="group" aria-labelledby={@labelledby} class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <div :for={{field, value, label} <- @fields} class="space-y-1">
        <label for={"#{@id}-#{field}"} class="block text-token-sm font-medium text-tymeslot-700">
          {label}
        </label>
        <input
          type="number"
          id={"#{@id}-#{field}"}
          name={input_name(@as, field)}
          value={value}
          min={@range.first}
          max={@range.last}
          step="1"
          placeholder={dgettext("dashboard_meeting_form", "No limit")}
          class="input"
          {@rest}
        />
      </div>
    </div>
    """
  end

  defp labels do
    [
      dgettext("dashboard_meeting_form", "Per day"),
      dgettext("dashboard_meeting_form", "Per week"),
      dgettext("dashboard_meeting_form", "Per month")
    ]
  end

  defp input_name(nil, field), do: Atom.to_string(field)
  defp input_name(as, field), do: "#{as}[#{field}]"
end
