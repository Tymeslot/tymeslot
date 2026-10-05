defmodule TymeslotWeb.Dashboard.Availability.PolicyCard do
  @moduledoc """
  Scheduling policy card for the availability page.

  The two buffers, the advance booking window and minimum notice belong to a
  single named schedule, so they are edited here beside the weekly pattern
  they constrain rather than on the account-wide meeting settings page.

  The quick-pick tags render from `CustomInputModeHelper.presets/1`, which is
  also what validates the `_preset` marker a tag click carries. Rendering them
  from literals is what let this card offer values the validator refused, so a
  click on one saved the value but left the card stuck in custom-input mode.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.CustomInputModeHelper

  # Each buffer has its own form and event, so editing one never resubmits the
  # other.
  @buffer_forms %{
    buffer_before_minutes: %{form_id: "buffer-before-form", event: "update_buffer_before_minutes"},
    buffer_after_minutes: %{form_id: "buffer-after-form", event: "update_buffer_after_minutes"}
  }

  @doc """
  Renders the scheduling policy settings for one schedule.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_input_mode, :map, required: true

  @spec policy_card(map()) :: Phoenix.LiveView.Rendered.t()
  def policy_card(assigns) do
    ~H"""
    <.card
      icon="hero-clock"
      title={dgettext("dashboard_availability", "Scheduling Preferences")}
      description={
        dgettext(
          "dashboard_availability",
          "These rules apply to every meeting type booked against this schedule."
        )
      }
    >
      <div class="space-y-8">
        <.buffer_settings
          schedule={@schedule}
          myself={@myself}
          custom_input_mode={@custom_input_mode}
        />
        <.advance_booking_days_setting
          schedule={@schedule}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :advance_booking_days, false)}
        />
        <.min_advance_hours_setting
          schedule={@schedule}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :min_advance_hours, false)}
        />
      </div>
    </.card>
    """
  end

  @doc """
  The buffer section, stacked as two settings. Buffers pad the booking being
  offered, not the meetings already in the calendar: a slot is offered only
  when the before-buffer ahead of it and the after-buffer behind it are free.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_input_mode, :map, required: true

  @spec buffer_settings(map()) :: Phoenix.LiveView.Rendered.t()
  def buffer_settings(assigns) do
    ~H"""
    <div>
      <label class="label">
        {dgettext("dashboard_availability", "Buffer Time")}
      </label>

      <div class="space-y-6">
        <.buffer_setting
          field={:buffer_before_minutes}
          schedule={@schedule}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :buffer_before_minutes, false)}
        />
        <.buffer_setting
          field={:buffer_after_minutes}
          schedule={@schedule}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :buffer_after_minutes, false)}
        />
      </div>
    </div>
    """
  end

  @doc """
  One buffer, before or after, with the same preset tags and custom input as
  the other policy settings.
  """
  attr :field, :atom, required: true, values: [:buffer_before_minutes, :buffer_after_minutes]
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec buffer_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def buffer_setting(assigns) do
    %{form_id: form_id, event: event} = Map.fetch!(@buffer_forms, assigns.field)

    assigns =
      assign(assigns,
        form_id: form_id,
        event: event,
        param: Atom.to_string(assigns.field),
        range: Constraints.buffer_minutes_range(),
        buffer_value:
          if(assigns.schedule, do: Map.fetch!(assigns.schedule, assigns.field), else: 0),
        presets: CustomInputModeHelper.presets(assigns.field)
      )

    ~H"""
    <div>
      <p id={"#{@form_id}-label"} class="mb-3 text-token-sm font-bold text-tymeslot-700">
        {buffer_title(@field)}
      </p>

      <%!-- Tag-based Selection --%>
      <form id={@form_id} phx-change={@event} phx-debounce="300" phx-target={@myself}>
        <div
          class="flex flex-wrap items-center gap-3"
          role="group"
          aria-labelledby={"#{@form_id}-label"}
        >
          <%!-- Quick preset tags --%>
          <%= for minutes <- @presets do %>
            <button
              type="button"
              phx-click={@event}
              {%{"phx-value-#{@param}" => minutes}}
              phx-value-_preset="true"
              phx-target={@myself}
              class={[
                "btn-tag-selector btn-tag-selector-primary",
                if(@buffer_value == minutes and not @custom_mode,
                  do: "btn-tag-selector-primary--active"
                )
              ]}
            >
              {buffer_label(minutes)}
            </button>
          <% end %>

          <%!-- Custom input tag --%>
          <%= if @custom_mode or @buffer_value not in @presets do %>
            <div class="btn-tag-selector btn-tag-selector-primary--active p-0 overflow-hidden">
              <input
                type="number"
                min={@range.first}
                max={@range.last}
                step="5"
                value={@buffer_value}
                name={@param}
                aria-labelledby={"#{@form_id}-label"}
                class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-hidden rounded-l-token-xl"
                placeholder="0"
              />
              <span class="pr-3 py-2 text-token-sm font-black text-turquoise-700">
                {dgettext("dashboard_availability", "min")}
              </span>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="focus_custom_input"
              phx-value-setting={@param}
              phx-target={@myself}
              class="btn-tag-selector btn-tag-selector-primary"
            >
              {dgettext("dashboard_availability", "Custom")}
            </button>
          <% end %>
        </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        {buffer_help(@field)}
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring how far in advance appointments can be booked.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec advance_booking_days_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def advance_booking_days_setting(assigns) do
    assigns =
      assign(assigns,
        booking_days: if(assigns.schedule, do: assigns.schedule.advance_booking_days, else: 90),
        presets: CustomInputModeHelper.presets(:advance_booking_days)
      )

    ~H"""
    <div>
      <label class="label">
        {dgettext("dashboard_availability", "How Far in Advance Can People Book")}
      </label>

      <%!-- Tag-based Selection --%>
      <form
        id="advance-booking-days-form"
        phx-change="update_advance_booking_days"
        phx-debounce="300"
        phx-target={@myself}
      >
        <div class="flex flex-wrap items-center gap-3">
          <%!-- Quick preset tags --%>
          <%= for days <- @presets do %>
            <button
              type="button"
              phx-click="update_advance_booking_days"
              phx-value-advance_booking_days={days}
              phx-value-_preset="true"
              phx-target={@myself}
              class={[
                "btn-tag-selector btn-tag-selector-primary",
                if(@booking_days == days and not @custom_mode,
                  do: "btn-tag-selector-primary--active"
                )
              ]}
            >
              {booking_days_label(days)}
            </button>
          <% end %>

          <%!-- Custom input tag --%>
          <%= if @custom_mode or @booking_days not in @presets do %>
            <div class="btn-tag-selector btn-tag-selector-primary--active p-0 overflow-hidden">
              <input
                type="number"
                min="1"
                max="365"
                step="1"
                value={@booking_days}
                name="advance_booking_days"
                class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-hidden rounded-l-token-xl"
                placeholder="90"
              />
              <span class="pr-3 py-2 text-token-sm font-black text-turquoise-700">
                {dgettext("dashboard_availability", "days")}
              </span>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="focus_custom_input"
              phx-value-setting="advance_booking_days"
              phx-target={@myself}
              class="btn-tag-selector btn-tag-selector-primary"
            >
              {dgettext("dashboard_availability", "Custom")}
            </button>
          <% end %>
        </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "Maximum number of days into the future that appointments can be booked."
        )}
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring minimum booking notice required.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec min_advance_hours_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def min_advance_hours_setting(assigns) do
    assigns =
      assign(assigns,
        notice_hours: if(assigns.schedule, do: assigns.schedule.min_advance_hours, else: 24),
        presets: CustomInputModeHelper.presets(:min_advance_hours)
      )

    ~H"""
    <div>
      <label class="label">
        {dgettext("dashboard_availability", "Minimum Booking Notice")}
      </label>

      <%!-- Tag-based Selection --%>
      <form
        id="min-advance-hours-form"
        phx-change="update_min_advance_hours"
        phx-debounce="300"
        phx-target={@myself}
      >
        <div class="flex flex-wrap items-center gap-3">
          <%!-- Quick preset tags --%>
          <%= for hours <- @presets do %>
            <button
              type="button"
              phx-click="update_min_advance_hours"
              phx-value-min_advance_hours={hours}
              phx-value-_preset="true"
              phx-target={@myself}
              class={[
                "btn-tag-selector btn-tag-selector-primary",
                if(@notice_hours == hours and not @custom_mode,
                  do: "btn-tag-selector-primary--active"
                )
              ]}
            >
              {notice_hours_label(hours)}
            </button>
          <% end %>

          <%!-- Custom input tag --%>
          <%= if @custom_mode or @notice_hours not in @presets do %>
            <div class="btn-tag-selector btn-tag-selector-primary--active p-0 overflow-hidden">
              <input
                type="number"
                min="0"
                max="168"
                step="1"
                value={@notice_hours}
                name="min_advance_hours"
                class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-hidden rounded-l-token-xl"
                placeholder="24"
              />
              <span class="pr-3 py-2 text-token-sm font-black text-turquoise-700">
                {dgettext("dashboard_availability", "hours")}
              </span>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="focus_custom_input"
              phx-value-setting="min_advance_hours"
              phx-target={@myself}
              class="btn-tag-selector btn-tag-selector-primary"
            >
              {dgettext("dashboard_availability", "Custom")}
            </button>
          <% end %>
        </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "Minimum hours of notice required before an appointment can be booked."
        )}
      </p>
    </div>
    """
  end

  # Tag labels. These cover the preset lists above with room to spare; a preset
  # added without a label here raises on render rather than rendering a blank
  # tag, which is the failure we want to hear about.

  defp buffer_title(:buffer_before_minutes),
    do: dgettext("dashboard_availability", "Before a new booking")

  defp buffer_title(:buffer_after_minutes),
    do: dgettext("dashboard_availability", "After a new booking")

  defp buffer_help(:buffer_before_minutes),
    do:
      dgettext(
        "dashboard_availability",
        "A new booking can start this long after your previous meeting ends, at the earliest."
      )

  defp buffer_help(:buffer_after_minutes),
    do:
      dgettext(
        "dashboard_availability",
        "A new booking must end at least this long before your next meeting starts."
      )

  defp buffer_label(0), do: dgettext("dashboard_availability", "No buffer")

  defp buffer_label(minutes),
    do: dgettext("dashboard_availability", "%{minutes} min", minutes: minutes)

  defp booking_days_label(7), do: dgettext("dashboard_availability", "1 week")
  defp booking_days_label(14), do: dgettext("dashboard_availability", "2 weeks")
  defp booking_days_label(30), do: dgettext("dashboard_availability", "1 month")
  defp booking_days_label(60), do: dgettext("dashboard_availability", "2 months")
  defp booking_days_label(90), do: dgettext("dashboard_availability", "3 months")
  defp booking_days_label(180), do: dgettext("dashboard_availability", "6 months")
  defp booking_days_label(365), do: dgettext("dashboard_availability", "1 year")

  defp notice_hours_label(0), do: dgettext("dashboard_availability", "instant")
  defp notice_hours_label(1), do: dgettext("dashboard_availability", "1 hour")
  defp notice_hours_label(3), do: dgettext("dashboard_availability", "3 hours")
  defp notice_hours_label(4), do: dgettext("dashboard_availability", "4 hours")
  defp notice_hours_label(6), do: dgettext("dashboard_availability", "6 hours")
  defp notice_hours_label(12), do: dgettext("dashboard_availability", "12 hours")
  defp notice_hours_label(24), do: dgettext("dashboard_availability", "1 day")
  defp notice_hours_label(48), do: dgettext("dashboard_availability", "2 days")
  defp notice_hours_label(168), do: dgettext("dashboard_availability", "1 week")
end
