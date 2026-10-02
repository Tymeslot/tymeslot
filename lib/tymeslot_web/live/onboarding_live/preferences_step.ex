defmodule TymeslotWeb.OnboardingLive.PreferencesStep do
  @moduledoc """
  Scheduling preference step components for the onboarding flow.

  Each preference (buffers, booking window, minimum notice) is
  rendered as its own step with preset/custom toggle behaviour.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.TextHelpers

  @doc """
  Renders the buffer step: a row for the time kept free before each booking,
  and one for the time kept free after it. Both sit in one form, so the step's
  change event carries whichever row was edited.
  """
  attr :buffer_before_minutes, :integer, required: true
  attr :buffer_after_minutes, :integer, required: true
  attr :form_errors, :map, required: true

  attr :custom_input_mode, :map,
    default: %{
      buffer_before_minutes: false,
      buffer_after_minutes: false,
      advance_booking_days: false,
      min_advance_hours: false
    }

  @spec buffer_time_step(map()) :: Phoenix.LiveView.Rendered.t()
  def buffer_time_step(assigns) do
    ~H"""
    <form
      id="onboarding-buffer-time-form"
      phx-change="update_scheduling_preferences"
      phx-debounce="300"
      class="onboarding-form"
    >
      <p class="onboarding-preference-example">
        {buffer_example(@buffer_before_minutes, @buffer_after_minutes)}
      </p>

      <.buffer_row
        id="onboarding-buffer-before"
        field={:buffer_before_minutes}
        label={dpgettext("onboarding_wizard", "buffer", "Before")}
        aria_label={dgettext("onboarding_wizard", "Custom buffer before, in minutes")}
        value={@buffer_before_minutes}
        form_errors={@form_errors}
        custom_input_mode={@custom_input_mode}
      />

      <.buffer_row
        id="onboarding-buffer-after"
        field={:buffer_after_minutes}
        label={dpgettext("onboarding_wizard", "buffer", "After")}
        aria_label={dgettext("onboarding_wizard", "Custom buffer after, in minutes")}
        value={@buffer_after_minutes}
        form_errors={@form_errors}
        custom_input_mode={@custom_input_mode}
      />
    </form>
    """
  end

  attr :id, :string, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :aria_label, :string, required: true
  attr :value, :integer, required: true
  attr :form_errors, :map, required: true
  attr :custom_input_mode, :map, required: true

  defp buffer_row(assigns) do
    assigns =
      assign(assigns,
        param: Atom.to_string(assigns.field),
        custom_mode: Map.get(assigns.custom_input_mode, assigns.field, false)
      )

    ~H"""
    <div id={@id} class="onboarding-form-group">
      <p id={"#{@id}-label"} class="label">{@label}</p>

      <div class="onboarding-preference-presets" role="group" aria-labelledby={"#{@id}-label"}>
        <%= for {label, value} <- StepConfig.buffer_time_options(@field) do %>
          <button
            type="button"
            phx-click="update_scheduling_preferences"
            {%{"phx-value-#{@param}" => value}}
            phx-value-_preset="true"
            class={[
              "btn-tag-selector btn-tag-selector-primary",
              if(@value == value and not @custom_mode, do: "btn-tag-selector-primary--active")
            ]}
          >
            {label}
          </button>
        <% end %>

        <.custom_input_toggle
          field_name={@param}
          current_value={@value}
          preset_values={CustomInputModeHelper.presets(@field)}
          constraints={StepConfig.buffer_constraints()}
          style_variant="primary"
          custom_mode={@custom_mode}
          aria_label={@aria_label}
        />
      </div>

      <%= for message <- FormValidationHelpers.field_errors(@form_errors, @field) do %>
        <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the booking window preference step.
  """
  attr :advance_booking_days, :integer, required: true
  attr :form_errors, :map, required: true

  attr :custom_input_mode, :map,
    default: %{
      buffer_before_minutes: false,
      buffer_after_minutes: false,
      advance_booking_days: false,
      min_advance_hours: false
    }

  @spec booking_window_step(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_window_step(assigns) do
    ~H"""
    <form
      id="onboarding-booking-window-form"
      phx-change="update_scheduling_preferences"
      phx-debounce="300"
      class="onboarding-form"
    >
      <p class="onboarding-preference-example">
        {window_example(@advance_booking_days)}
      </p>

      <div class="onboarding-preference-presets">
        <%= for {label, value} <- StepConfig.advance_booking_options() do %>
          <button
            type="button"
            phx-click="update_scheduling_preferences"
            phx-value-advance_booking_days={value}
            phx-value-_preset="true"
            class={[
              "btn-tag-selector btn-tag-selector-secondary",
              if(
                @advance_booking_days == value and
                  not Map.get(@custom_input_mode, :advance_booking_days, false),
                do: "btn-tag-selector-secondary--active"
              )
            ]}
          >
            {label}
          </button>
        <% end %>

        <.custom_input_toggle
          field_name="advance_booking_days"
          current_value={@advance_booking_days}
          preset_values={CustomInputModeHelper.presets(:advance_booking_days)}
          constraints={StepConfig.advance_booking_constraints()}
          style_variant="secondary"
          custom_mode={Map.get(@custom_input_mode, :advance_booking_days, false)}
        />
      </div>

      <%= for message <- FormValidationHelpers.field_errors(@form_errors, :advance_booking_days) do %>
        <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>
    </form>
    """
  end

  @doc """
  Renders the minimum notice preference step.
  """
  attr :min_advance_hours, :integer, required: true
  attr :form_errors, :map, required: true

  attr :custom_input_mode, :map,
    default: %{
      buffer_before_minutes: false,
      buffer_after_minutes: false,
      advance_booking_days: false,
      min_advance_hours: false
    }

  @spec minimum_notice_step(map()) :: Phoenix.LiveView.Rendered.t()
  def minimum_notice_step(assigns) do
    ~H"""
    <form
      id="onboarding-min-notice-form"
      phx-change="update_scheduling_preferences"
      phx-debounce="300"
      class="onboarding-form"
    >
      <p class="onboarding-preference-example">
        {notice_example(@min_advance_hours)}
      </p>

      <div class="onboarding-preference-presets">
        <%= for {label, value} <- StepConfig.min_advance_options() do %>
          <button
            type="button"
            phx-click="update_scheduling_preferences"
            phx-value-min_advance_hours={value}
            phx-value-_preset="true"
            class={[
              "btn-tag-selector btn-tag-selector-tertiary",
              if(
                @min_advance_hours == value and
                  not Map.get(@custom_input_mode, :min_advance_hours, false),
                do: "btn-tag-selector-tertiary--active"
              )
            ]}
          >
            {label}
          </button>
        <% end %>

        <.custom_input_toggle
          field_name="min_advance_hours"
          current_value={@min_advance_hours}
          preset_values={CustomInputModeHelper.presets(:min_advance_hours)}
          constraints={StepConfig.min_advance_constraints()}
          style_variant="tertiary"
          custom_mode={Map.get(@custom_input_mode, :min_advance_hours, false)}
        />
      </div>

      <%= for message <- FormValidationHelpers.field_errors(@form_errors, :min_advance_hours) do %>
        <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>
    </form>
    """
  end

  attr :field_name, :string, required: true
  attr :current_value, :integer, required: true
  attr :preset_values, :list, required: true
  attr :constraints, :map, required: true
  attr :style_variant, :string, required: true
  attr :custom_mode, :boolean, required: true
  attr :aria_label, :string, default: nil

  defp custom_input_toggle(assigns) do
    ~H"""
    <%= if @custom_mode or @current_value not in @preset_values do %>
      <div class={"btn-tag-selector btn-tag-selector-#{@style_variant}--active p-0! overflow-hidden"}>
        <input
          type="number"
          min={@constraints.min}
          max={@constraints.max}
          step={@constraints.step}
          value={@current_value}
          name={@field_name}
          aria-label={@aria_label}
          class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-hidden rounded-l-xl"
          placeholder={to_string(@constraints.min)}
        />
        <span class={"pr-3 py-2 text-token-sm font-black text-#{@constraints.color}-700"}>
          {@constraints.unit}
        </span>
      </div>
    <% else %>
      <button
        type="button"
        phx-click="focus_custom_input"
        phx-value-setting={@field_name}
        aria-label={@aria_label}
        class={"btn-tag-selector btn-tag-selector-#{@style_variant}"}
      >
        {dgettext("onboarding_wizard", "Custom")}
      </button>
    <% end %>
    """
  end

  # -------------------------------------------------------------------
  # Worked-example sentences — reflect the currently chosen value so the
  # explanation stays accurate as the user clicks through presets/custom.
  # -------------------------------------------------------------------

  @example_meeting_start ~T[13:00:00]
  @example_meeting_end ~T[14:00:00]

  defp buffer_example(0, 0),
    do:
      dgettext(
        "onboarding_wizard",
        "With no buffers, a new booking can sit right next to an existing meeting."
      )

  # A new booking needs its before-buffer clear after an existing meeting ends,
  # and its after-buffer clear before one starts.
  defp buffer_example(buffer_before, buffer_after) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    dgettext(
      "onboarding_wizard",
      "If you have a meeting from %{start_time} to %{end_time}, a new booking after it can start at %{next_start} at the earliest, and one before it must end by %{latest_end}.",
      start_time: LocaleFormat.format_time(@example_meeting_start, locale),
      end_time: LocaleFormat.format_time(@example_meeting_end, locale),
      next_start:
        LocaleFormat.format_time(Time.add(@example_meeting_end, buffer_before * 60), locale),
      latest_end:
        LocaleFormat.format_time(Time.add(@example_meeting_start, -buffer_after * 60), locale)
    )
  end

  defp window_example(nil), do: window_example(14)

  defp window_example(days) do
    phrase = TextHelpers.humanize_days(days)

    dgettext(
      "onboarding_wizard",
      "Someone visiting your page today can only book up to %{period} ahead - no further.",
      period: phrase
    )
  end

  defp notice_example(nil), do: notice_example(3)

  defp notice_example(0),
    do:
      dgettext(
        "onboarding_wizard",
        "With no minimum notice, someone can book a slot that starts any time from now."
      )

  defp notice_example(hours) do
    phrase = humanize_hours(hours)

    dgettext(
      "onboarding_wizard",
      "With %{notice} of notice, nobody can book a slot that starts sooner than %{notice} from now.",
      notice: phrase
    )
  end

  defp humanize_hours(1),
    do: dngettext("onboarding_wizard", "%{count} hour", "%{count} hours", 1, count: 1)

  defp humanize_hours(24),
    do: dngettext("onboarding_wizard", "%{count} day", "%{count} days", 1, count: 1)

  defp humanize_hours(48),
    do: dngettext("onboarding_wizard", "%{count} day", "%{count} days", 2, count: 2)

  defp humanize_hours(hours),
    do: dngettext("onboarding_wizard", "%{count} hour", "%{count} hours", hours, count: hours)
end
