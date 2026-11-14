defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.SeriesComponent do
  @moduledoc """
  Quill theme step for booking a series (`Journey.Facts.Series`), shown
  after the time when the meeting type offers one. The time picked is the
  first session.

  A recurring series names its rhythm and lets the booker set how many
  sessions it has; a flexible one lets the booker add sessions at other
  offered times. Either way every session is listed with how it stands,
  and the booker moves on once all of them can be booked. Where the type
  also takes a single session, a link books just the time picked.

  It belongs to the second step of the indicator, "Date & Time".
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SeriesParts
  alias TymeslotWeb.Themes.Shared.SeriesPicker
  alias TymeslotWeb.Themes.Shared.StepEvents
  use TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    choice = assigns[:series_choice]
    type = assigns[:meeting_type]

    assigns =
      assign(assigns,
        navigable_steps: Runtime.navigable_steps(assigns),
        step_numbers: Runtime.step_numbers(assigns),
        choice: choice,
        mode: type && type.series_mode,
        min: type && type.series_min_occurrences,
        max: type && type.series_max_occurrences,
        rows: Series.rows(assigns),
        unavailable?: Series.unavailable(assigns) != [],
        known?: Series.known?(assigns),
        first_start: Series.first_start(assigns)
      )

    ~H"""
    <div
      class="container quill-container flex-1"
      data-locale={@locale}
      data-testid="series-step"
      id={assigns[:moment] && "#{assigns[:moment]}-step"}
      data-moment={assigns[:moment]}
      data-moment-state={assigns[:moment_state]}
    >
      <.page_layout
        show_steps={true}
        navigable_steps={@navigable_steps}
        step_numbers={@step_numbers}
        current_step={2}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="overview-content-area flex items-start justify-center">
          <div class="w-full">
            <.glass_morphism_card class="booker-card series-card" data-testid="booker-card">
              <div class="overview-card-body">
                <JourneyComponents.moment_heading
                  tag="h1"
                  moment={assigns[:moment]}
                  moment_state={assigns[:moment_state]}
                  focus={assigns[:journey_focus]}
                  class="section-header overview-title"
                >
                  {heading(@mode, @min, @max)}
                </JourneyComponents.moment_heading>
                <p class="overview-description text-glass-primary" data-testid="chosen-meeting-type">
                  {@meeting_type && @meeting_type.name} · {BookingText.duration_label(assigns)}
                </p>

                <SeriesParts.announcement rows={@rows} checking={@series_checking?} />

                <%= if @choice == :single do %>
                  <div class="series-single" data-testid="series-single">
                    <p class="series-single-text">
                      {dgettext("booking_series", "You're booking just this session:")}
                      <strong>
                        {LocalizationHelpers.format_meeting_datetime_compact(
                          @first_start,
                          @user_timezone
                        )}
                      </strong>
                    </p>
                    <button
                      type="button"
                      class="series-link"
                      phx-click="series_as_series"
                      phx-target={@myself}
                      data-testid="series-as-series"
                    >
                      {dgettext("booking_series", "Book a series instead")}
                    </button>
                  </div>
                <% else %>
                  <SeriesParts.rule
                    meeting_type={@meeting_type}
                    first_start={@first_start}
                    timezone={@user_timezone}
                    locale={@locale}
                  />
                  <p :if={@mode == :flexible and @min != @max} class="series-hint">
                    {dgettext("booking_series", "Choose between %{min} and %{max} sessions.",
                      min: @min,
                      max: @max
                    )}
                  </p>

                  <.count_control
                    :if={@mode == :recurring and is_map(@choice)}
                    count={@choice.count}
                    min={@min}
                    max={@max}
                    target={@myself}
                  />

                  <p class="series-zone">
                    {dgettext("booking_series", "Times in %{zone}",
                      zone: LocalizationHelpers.format_zone_label(nil, nil, @user_timezone)
                    )}
                  </p>

                  <SeriesParts.occurrence_list
                    rows={@rows}
                    timezone={@user_timezone}
                    checking={@series_checking?}
                    removable={@mode == :flexible}
                    refocus={
                      @series_refocus and @mode == :flexible and is_map(@choice) and
                        @choice.count >= @max
                    }
                    target={@myself}
                  />

                  <p :if={@series_checking?} class="series-checking" role="status">
                    <span class="series-checking-dot" aria-hidden="true"></span>
                    {dgettext("booking_series", "Checking availability…")}
                  </p>

                  <.flexible_picker
                    :if={@mode == :flexible and is_map(@choice)}
                    choice={@choice}
                    max={@max}
                    picker={@series_picker}
                    days={SeriesPicker.days(assigns)}
                    earlier?={SeriesPicker.earlier?(assigns)}
                    later?={SeriesPicker.later?(assigns)}
                    refocus={@series_refocus}
                    timezone={@user_timezone}
                    target={@myself}
                  />

                  <SeriesParts.check_error
                    :if={@series_error}
                    reason={@series_error}
                    target={@myself}
                  />
                  <SeriesParts.unavailable_notice :if={@unavailable?} target={@myself} />

                  <SeriesParts.total
                    :if={!@is_rescheduling and is_map(@choice)}
                    meeting_type={@meeting_type}
                    currency={@host_currency}
                    locale={@locale}
                    count={@choice.count}
                  />

                  <button
                    :if={@series_single_allowed?}
                    type="button"
                    class="series-link"
                    phx-click="series_single"
                    phx-target={@myself}
                    data-testid="series-book-single"
                  >
                    {dgettext("booking_series", "Book just this session")}
                  </button>
                <% end %>

                <div class="schedule-actions overview-next-action animate-fade-in-up">
                  <.action_button
                    type="button"
                    phx-click="back_step"
                    phx-target={@myself}
                    data-testid="back-step"
                    data-intent="back"
                    variant={:secondary}
                    class="flex-1 gap-2"
                  >
                    <.icon name="hero-arrow-left" class="inline-icon" />
                    {dgettext("booking", "Back")}
                  </.action_button>
                  <.action_button
                    phx-click="next_step"
                    phx-target={@myself}
                    data-testid="next-step"
                    data-intent="continue"
                    disabled={not @known?}
                    aria-describedby={if not @known?, do: "series-next-hint"}
                    class="flex-1 gap-2"
                  >
                    {dgettext("booking", "Next")}
                    <.icon name="hero-arrow-right" class="inline-icon" />
                  </.action_button>
                </div>
                <p
                  :if={not @known? and not @series_checking?}
                  id="series-next-hint"
                  class="mt-2 text-center text-sm opacity-80"
                >
                  {next_hint(@mode, @choice, @min)}
                </p>
              </div>
            </.glass_morphism_card>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end

  attr :count, :integer, required: true
  attr :min, :integer, required: true
  attr :max, :integer, required: true
  attr :target, :any, required: true

  # A package of a fixed size has nothing to set: its size is stated.
  defp count_control(%{min: same, max: same} = assigns) do
    ~H"""
    <p class="series-count series-count--fixed" data-testid="series-count">
      {SeriesParts.count_label(@count)}
    </p>
    """
  end

  defp count_control(assigns) do
    ~H"""
    <div
      class="series-count"
      role="group"
      aria-label={dgettext("booking_series", "Number of sessions")}
    >
      <button
        type="button"
        class="series-count__step"
        phx-click="series_set_count"
        phx-value-count={@count - 1}
        phx-target={@target}
        disabled={@count <= @min}
        data-fact="series"
        data-value={@count - 1}
        data-testid="series-count-less"
        aria-label={dgettext("booking_series", "One session fewer")}
      >
        <.icon name="hero-minus-mini" class="series-count__icon" />
      </button>
      <output class="series-count__value" data-testid="series-count" aria-live="polite">
        {SeriesParts.count_label(@count)}
      </output>
      <button
        type="button"
        class="series-count__step"
        phx-click="series_set_count"
        phx-value-count={@count + 1}
        phx-target={@target}
        disabled={@count >= @max}
        data-fact="series"
        data-value={@count + 1}
        data-testid="series-count-more"
        aria-label={dgettext("booking_series", "One session more")}
      >
        <.icon name="hero-plus-mini" class="series-count__icon" />
      </button>
    </div>
    """
  end

  attr :choice, :map, required: true
  attr :max, :integer, required: true
  attr :picker, :any, required: true
  attr :days, :list, required: true
  attr :earlier?, :boolean, required: true
  attr :later?, :boolean, required: true
  attr :refocus, :boolean, default: false
  attr :timezone, :string, required: true
  attr :target, :any, required: true

  defp flexible_picker(assigns) do
    ~H"""
    <div class="series-picker-area">
      <button
        :if={is_nil(@picker) and @choice.count < @max}
        type="button"
        id="series-add"
        class="series-add"
        phx-mounted={SeriesParts.refocus(@refocus)}
        phx-click="series_picker_open"
        phx-target={@target}
        data-testid="series-add"
      >
        <.icon name="hero-plus-mini" class="series-add-icon" />
        {dgettext("booking_series", "Add a session")}
      </button>

      <div :if={@picker} class="series-picker" data-testid="series-picker">
        <div class="series-picker__nav">
          <button
            type="button"
            class="calendar-nav-button series-picker__arrow p-1 rounded-lg"
            phx-click="series_picker_week"
            phx-value-dir="prev"
            phx-target={@target}
            data-testid="series-picker-earlier"
            disabled={not @earlier?}
            aria-label={dgettext("booking", "Previous week")}
          >
            <.icon name="hero-arrow-left" class="inline-icon stroke-2" />
          </button>
          <span class="series-picker__week">
            {LocalizationHelpers.get_week_display(@picker.week_start)}
          </span>
          <button
            type="button"
            class="calendar-nav-button series-picker__arrow p-1 rounded-lg"
            phx-click="series_picker_week"
            phx-value-dir="next"
            phx-target={@target}
            data-testid="series-picker-later"
            disabled={not @later?}
            aria-label={dgettext("booking", "Next week")}
          >
            <.icon name="hero-arrow-right" class="inline-icon stroke-2" />
          </button>
          <button
            type="button"
            class="series-picker__close"
            phx-click="series_picker_close"
            phx-target={@target}
            aria-label={dgettext("booking_series", "Close")}
          >
            <.icon name="hero-x-mark-mini" class="series-list__remove-icon" />
          </button>
        </div>

        <p :if={@picker.loading?} class="series-checking" role="status">
          <span class="series-checking-dot" aria-hidden="true"></span>
          {dgettext("booking_series", "Loading times…")}
        </p>
        <SeriesParts.check_error
          :if={@picker.error}
          reason={@picker.error}
          retry_event="series_picker_retry"
          target={@target}
        />
        <SeriesParts.picker_slots
          :if={not @picker.loading? and is_nil(@picker.error)}
          days={@days}
          day={@picker.day}
          timezone={@timezone}
          target={@target}
        />
      </div>
    </div>
    """
  end

  # The recurring series repeats the time picked; a flexible one is chosen
  # session by session, its size named when it is fixed.
  defp heading(:flexible, same, same) when is_integer(same),
    do:
      dngettext(
        "booking_series",
        "Choose your %{count} session",
        "Choose your %{count} sessions",
        same
      )

  defp heading(:flexible, _min, _max), do: dgettext("booking_series", "Choose your sessions")
  defp heading(_mode, _min, _max), do: dgettext("booking_series", "Book a series")

  defp next_hint(:flexible, %{count: count}, min) when is_integer(min) and count < min,
    do:
      dngettext(
        "booking_series",
        "Add at least %{count} more session to continue.",
        "Add at least %{count} more sessions to continue.",
        min - count
      )

  defp next_hint(_mode, _choice, _min),
    do: dgettext("booking_series", "Every session must be available to continue.")
end
