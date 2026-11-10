defmodule TymeslotWeb.OnboardingLive.MeetingStep do
  @moduledoc """
  The meeting step of the onboarding flow, in two groups: the meeting people
  book (its name, length and place) and when they can book it (a preset
  week, or days and one window of the host's own, whose controls show once
  the host picks "Custom" or their week is one no preset describes).

  The step only draws the forms; their state and events are
  `MeetingHandlers`'. Every chip row is a `segmented_control/1` that wraps
  rather than scrolls (`overflow={:wrap}`): each row is a handful of short
  choices on its own line, so at any width and in any language every chip
  is whole, where a scrolling row would cut one mid-word. Every control is
  at least 44px tall.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents,
    only: [icon: 1, input: 1, segmented_control: 1, select: 1]

  alias Tymeslot.Onboarding.MeetingSetup
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.OnboardingLive.MeetingHandlers

  attr :meeting_form, :map, required: true
  attr :meeting_errors, :map, required: true

  attr :taken_names, :any,
    default: MapSet.new(),
    doc: "the names the host's other meeting types use, which no chip offers"

  attr :hours_form, :map, required: true
  attr :hours_open, :boolean, default: false, doc: "whether the day and time controls show"
  attr :video_integration, :any, default: nil, doc: "the integration a video place binds to"

  @doc """
  Renders the meeting step.
  """
  @spec meeting_step(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_step(assigns) do
    assigns =
      assign(assigns,
        locale: Gettext.get_locale(TymeslotWeb.Gettext),
        suggestions: MeetingHandlers.offered_suggestions(assigns.taken_names)
      )

    ~H"""
    <div id="onboarding-meeting-step" class="onboarding-form">
      <.form
        for={%{}}
        as={:meeting}
        id="meeting-form"
        phx-change="meeting_change"
        phx-submit="meeting_save"
        class="onboarding-form"
      >
        <div class="onboarding-form-group">
          <.input
            type="text"
            id="meeting-name"
            name="meeting[name]"
            value={@meeting_form.name}
            label={dgettext("onboarding_wizard", "What do people book you for?")}
            errors={List.wrap(@meeting_errors[:name])}
            maxlength={MeetingSetup.name_max_length()}
            autocomplete="off"
            phx-debounce="150"
            phx-blur="meeting_save"
          />
          <.segmented_control
            :if={@suggestions != []}
            id="meeting-name-suggestions"
            value={MeetingHandlers.suggestion_index(@meeting_form.name) || ""}
            on_change="meeting_suggestion"
            param="index"
            size={:lg}
            aria_label={dgettext("onboarding_wizard", "Suggested names")}
            overflow={:wrap}
            class="mt-1 onboarding-chips"
          >
            <:option
              :for={{name, index} <- @suggestions}
              value={index}
              label={name}
            />
          </.segmented_control>
        </div>

        <div
          class="onboarding-form-group"
          role="group"
          aria-labelledby="meeting-duration-label"
          aria-describedby={@meeting_errors[:duration_minutes] && "meeting-duration-error"}
        >
          <span id="meeting-duration-label" class="label">
            {dgettext("onboarding_wizard", "How long?")}
          </span>
          <.segmented_control
            id="meeting-duration"
            value={duration_value(@meeting_form)}
            on_change="meeting_duration"
            param="duration"
            size={:lg}
            aria_label={dgettext("onboarding_wizard", "Meeting length")}
            overflow={:wrap}
            class="onboarding-chips"
          >
            <:option
              :for={minutes <- MeetingHandlers.duration_presets()}
              value={minutes}
              label={dgettext("onboarding_wizard", "%{minutes} min", minutes: minutes)}
            />
            <:option value="other" label={dgettext("onboarding_wizard", "Other")} />
          </.segmented_control>
          <div :if={@meeting_form.other} class="flex items-end gap-2 mt-2">
            <.input
              type="number"
              id="meeting-duration-minutes"
              name="meeting[duration_input]"
              value={@meeting_form.duration_input}
              label={dgettext("onboarding_wizard", "Length in minutes")}
              min={MeetingSetup.duration_range().first}
              max={MeetingSetup.duration_range().last}
              step={MeetingSetup.duration_step()}
              inputmode="numeric"
              class="w-40"
              aria-describedby={@meeting_errors[:duration_minutes] && "meeting-duration-error"}
              phx-debounce="150"
              phx-blur="meeting_save"
            />
          </div>
          <p
            :if={@meeting_errors[:duration_minutes]}
            id="meeting-duration-error"
            class="mt-1 text-token-sm text-red-600 font-bold"
          >
            {@meeting_errors[:duration_minutes]}
          </p>
        </div>

        <div
          class="onboarding-form-group"
          role="group"
          aria-labelledby="meeting-location-label"
          aria-describedby={@meeting_errors[:location] && "meeting-location-error"}
        >
          <span id="meeting-location-label" class="label">
            {dgettext("onboarding_wizard", "Where?")}
          </span>
          <.segmented_control
            id="meeting-location"
            value={@meeting_form.location || ""}
            on_change="meeting_location"
            param="location"
            size={:lg}
            aria_label={dgettext("onboarding_wizard", "Where the meeting is held")}
            overflow={:wrap}
            class="onboarding-chips"
          >
            <:option
              value="video"
              icon="hero-video-camera"
              label={dgettext("onboarding_wizard", "Video call")}
            />
            <:option value="phone" icon="hero-phone" label={dgettext("onboarding_wizard", "Phone")} />
            <:option
              value="in_person"
              icon="hero-map-pin"
              label={dgettext("onboarding_wizard", "In person")}
            />
          </.segmented_control>
          <p :if={@meeting_form.location} class="onboarding-form-helper" data-role="location-helper">
            {location_helper(@meeting_form.location, @video_integration)}
          </p>
          <p
            :if={@meeting_errors[:location]}
            id="meeting-location-error"
            class="mt-1 text-token-sm text-red-600 font-bold"
          >
            {@meeting_errors[:location]}
          </p>
        </div>
      </.form>

      <section class="onboarding-form-group" aria-labelledby="meeting-hours-heading">
        <h2 id="meeting-hours-heading" class="label">
          {dgettext("onboarding_wizard", "When can people book you?")}
        </h2>

        <.segmented_control
          id="meeting-hours-preset"
          value={@hours_form.preset}
          on_change="hours_preset"
          param="preset"
          size={:lg}
          aria_label={dgettext("onboarding_wizard", "Weekly hours")}
          overflow={:wrap}
          class="onboarding-chips"
        >
          <:option value="weekdays" label={dgettext("onboarding_wizard", "Weekdays 9 to 5")} />
          <:option value="mornings" label={dgettext("onboarding_wizard", "Mornings")} />
          <:option value="afternoons" label={dgettext("onboarding_wizard", "Afternoons")} />
          <:option value="custom" label={dgettext("onboarding_wizard", "Custom")} />
        </.segmented_control>

        <%!-- Each day is named by the short form it shows, so a voice
             command that reads the button ("Mon") finds it; the full name
             is its description. --%>
        <div
          :if={@hours_open or @meeting_errors[:hours]}
          class="grid grid-cols-7 gap-1 mt-2"
          role="group"
          aria-label={dgettext("onboarding_wizard", "Days you take bookings")}
          aria-describedby={@meeting_errors[:hours] && "meeting-hours-error"}
        >
          <button
            :for={day <- 1..7}
            type="button"
            id={"meeting-day-#{day}"}
            phx-click="hours_toggle_day"
            phx-value-day={day}
            aria-pressed={to_string(day in @hours_form.days)}
            title={LocaleFormat.format_weekday_name(day, @locale, :full)}
            class={[
              "min-h-11 min-w-0 rounded-token-lg border text-token-sm font-semibold transition-colors",
              "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400",
              if(day in @hours_form.days,
                do: "bg-turquoise-700 border-turquoise-700 text-white",
                else: "bg-white border-tymeslot-200 text-tymeslot-500 hover:bg-tymeslot-50"
              )
            ]}
          >
            {LocaleFormat.format_weekday_name(day, @locale, :short)}
          </button>
        </div>

        <form
          :if={@hours_open or @meeting_errors[:hours]}
          id="meeting-hours-form"
          phx-change="hours_change"
          class="grid grid-cols-2 gap-3 mt-2"
        >
          <.select
            id="meeting-hours-start"
            name="hours[start]"
            value={@hours_form.start}
            options={time_options(@locale, @hours_form.start)}
            label={dgettext("onboarding_wizard", "From")}
            aria-describedby={@meeting_errors[:hours] && "meeting-hours-error"}
            phx-debounce="300"
          />
          <.select
            id="meeting-hours-end"
            name="hours[end]"
            value={@hours_form.end}
            options={time_options(@locale, @hours_form.end)}
            label={dgettext("onboarding_wizard", "To")}
            aria-describedby={@meeting_errors[:hours] && "meeting-hours-error"}
            phx-debounce="300"
          />
        </form>

        <p
          :if={@meeting_errors[:hours]}
          id="meeting-hours-error"
          class="mt-1 text-token-sm text-red-600 font-bold"
          data-role="hours-error"
        >
          <.icon name="hero-exclamation-circle-mini" class="w-4 h-4 inline-block align-text-bottom" />
          {@meeting_errors[:hours]}
        </p>
      </section>
    </div>
    """
  end

  defp duration_value(%{other: true}), do: "other"
  defp duration_value(%{duration: duration}), do: duration

  defp location_helper(:video, nil),
    do:
      dgettext(
        "onboarding_wizard",
        "You'll send the link after booking. Connect Zoom, Google Meet or others later in Settings."
      )

  defp location_helper(:video, integration),
    do:
      dgettext("onboarding_wizard", "Each booking gets its own %{provider} link.",
        provider: integration.name
      )

  defp location_helper(:phone, _integration),
    do: dgettext("onboarding_wizard", "People give their number when they book.")

  defp location_helper(:in_person, _integration),
    do:
      dgettext(
        "onboarding_wizard",
        "You'll arrange the address after booking. Add your places later in Settings."
      )

  # Every half hour of the day, worded in the host's clock, and the stored
  # time among them when it is off that grid (a 09:15 start set elsewhere),
  # so the select shows it rather than falling back to its first option.
  defp time_options(locale, current) do
    grid =
      for minutes <- 0..(24 * 60 - 30)//30, do: Time.new!(div(minutes, 60), rem(minutes, 60), 0)

    times =
      case Time.from_iso8601((current || "") <> ":00") do
        {:ok, time} -> Enum.sort(Enum.uniq([time | grid]), Time)
        {:error, _reason} -> grid
      end

    for time <- times,
        do: {LocaleFormat.format_time(time, locale), Calendar.strftime(time, "%H:%M")}
  end
end
