defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LengthsField do
  @moduledoc """
  The row of length inputs in the meeting type form: the primary duration,
  every further length the type offers, and the add/remove controls.

  Its own module because it is the one repeatable field on this form, and a
  repeatable field is several things at once — a row per value, an index in
  every input name, a suggestion for the next value, and a fold of the posted
  index map back onto a list. Left inline it was the largest single block in
  a form module that is already near the size at which this codebase splits
  one up.

  The events the buttons send (`add_length`, `remove_length`) are handled by
  `TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm`, which owns the
  form's assigns and its autosave; this module contributes the markup and the
  two pure functions that belong to it.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  # A new row starts with the next common length the type does not offer yet,
  # so it is valid straight away and the host only has to adjust it.
  @suggested_lengths [15, 30, 45, 60, 90, 120, 180, 240, 300, 360, 420, 480]

  attr :form_data, :map, required: true
  attr :form_errors, :map, default: %{}
  attr :type, :map, default: nil
  attr :myself, :any, required: true

  @doc """
  Renders the length fields for `form_data`.
  """
  @spec lengths_field(map()) :: Phoenix.LiveView.Rendered.t()
  def lengths_field(assigns) do
    assigns = assign(assigns, :extra_lengths, Map.get(assigns.form_data, "extra_lengths", []))

    ~H"""
    <%!-- The primary duration and up to seven further ones side by side.
          With more than one, the booker picks a length before a time. --%>
    <div class="md:col-span-2" id="meeting-type-lengths">
      <div class="flex flex-wrap items-end gap-3">
        <.input
          type="number"
          name="meeting_type[duration]"
          label={dgettext("dashboard_meeting_form", "Duration (minutes)")}
          value={Map.get(@form_data, "duration", if(@type, do: @type.duration_minutes, else: "30"))}
          min={Constraints.duration_minutes_opts()[:greater_than_or_equal_to]}
          max={Constraints.duration_minutes_opts()[:less_than_or_equal_to]}
          required
          placeholder="30"
          phx-change="validate_meeting_type"
          phx-debounce="500"
          phx-target={@myself}
          errors={
            FormValidationHelpers.field_errors(@form_errors, :duration)
            |> Enum.map(&Helpers.format_errors/1)
          }
          icon="hero-clock"
          class="w-44"
        />
        <div
          :for={{minutes, index} <- Enum.with_index(@extra_lengths)}
          class="flex items-center gap-1"
          data-testid="extra-length"
        >
          <.input
            type="number"
            id={"meeting-type-extra-length-#{index}"}
            name={"meeting_type[extra_lengths][#{index}]"}
            value={minutes}
            min={Constraints.duration_minutes_opts()[:greater_than_or_equal_to]}
            max={Constraints.duration_minutes_opts()[:less_than_or_equal_to]}
            required
            placeholder="60"
            aria-label={dgettext("dashboard_meeting_form", "Additional duration (minutes)")}
            phx-change="validate_meeting_type"
            phx-debounce="500"
            phx-target={@myself}
            class="w-28"
          />
          <button
            type="button"
            phx-click="remove_length"
            phx-value-index={index}
            phx-target={@myself}
            class="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-tymeslot-200 bg-white text-tymeslot-500 hover:text-red-600 hover:border-red-300"
            aria-label={dgettext("dashboard_meeting_form", "Remove this duration")}
            title={dgettext("dashboard_meeting_form", "Remove this duration")}
            data-testid="remove-length"
          >
            <.icon name="hero-trash" class="h-4 w-4" />
          </button>
        </div>
        <%!-- As tall as an input (h-12), so the button centres on the
              fields beside it rather than on their bottom edge. --%>
        <div
          :if={length(@extra_lengths) + 1 < Constraints.max_lengths_per_meeting_type()}
          class="flex h-12 items-center"
        >
          <button
            type="button"
            phx-click="add_length"
            phx-target={@myself}
            class="inline-flex h-9 w-9 items-center justify-center rounded-full border border-turquoise-200 bg-white text-turquoise-600 hover:text-turquoise-700 hover:border-turquoise-300"
            aria-label={dgettext("dashboard_meeting_form", "Offer another duration")}
            title={dgettext("dashboard_meeting_form", "Offer another duration")}
            data-testid="add-length"
          >
            <.icon name="hero-plus" class="h-5 w-5" />
          </button>
        </div>
      </div>
      <p
        :for={message <- FormValidationHelpers.field_errors(@form_errors, :extra_lengths)}
        class="mt-1 text-token-sm text-red-600"
        data-testid="extra-lengths-error"
      >
        {Helpers.format_errors(message)}
      </p>
      <p class="mt-1 text-token-sm text-tymeslot-600">
        {dgettext(
          "dashboard_meeting_form",
          "Enter a duration between %{min} and %{max} minutes",
          min: Constraints.duration_minutes_opts()[:greater_than_or_equal_to],
          max: Constraints.duration_minutes_opts()[:less_than_or_equal_to]
        )}
        <span :if={@extra_lengths != []}>
          {dgettext(
            "dashboard_meeting_form",
            "Bookers choose one of these durations before picking a time. Each booking lasts the duration chosen; the price is the same for all."
          )}
        </span>
      </p>
    </div>
    """
  end

  @doc """
  The length a newly added row starts on: the next common length the type does
  not offer yet, past the longest it already has.
  """
  @spec suggest(map()) :: String.t()
  def suggest(form_data) do
    taken = taken_lengths(form_data)
    longest = Enum.max(taken, fn -> 0 end)

    candidate =
      Enum.find(@suggested_lengths, &(&1 > longest and &1 not in taken)) ||
        Enum.find(@suggested_lengths, &(&1 not in taken)) || 60

    to_string(candidate)
  end

  @doc """
  Folds the `%{"0" => "45", "1" => "90"}` map the inputs post back onto the
  list the form holds, leaving every other param untouched.

  Indices that name no existing row are dropped rather than appended: they can
  only come from a stale or crafted post, and appending would add a length the
  host never asked for.
  """
  @spec fold_params(map(), map()) :: map()
  def fold_params(%{"extra_lengths" => %{} = changed} = params, form_data) do
    current = Map.get(form_data, "extra_lengths", [])

    folded =
      Enum.reduce(changed, current, fn {index, value}, acc ->
        case Integer.parse(to_string(index)) do
          {position, ""} when position >= 0 and position < length(acc) ->
            List.replace_at(acc, position, to_string(value))

          _other ->
            acc
        end
      end)

    Map.put(params, "extra_lengths", folded)
  end

  def fold_params(params, _form_data), do: params

  defp taken_lengths(form_data) do
    values = [Map.get(form_data, "duration") | Map.get(form_data, "extra_lengths", [])]

    Enum.flat_map(values, fn value ->
      case Integer.parse(to_string(value)) do
        {minutes, ""} -> [minutes]
        _other -> []
      end
    end)
  end
end
