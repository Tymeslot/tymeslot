defmodule TymeslotWeb.Themes.Shared.SeriesChooser do
  @moduledoc """
  The body every theme's series moment draws (`Journey.Facts.Series`),
  between the theme's own heading and its own way on: the live-region
  announcement, then either the single session a booker chose instead
  (with the way back to a series), or the series itself: the rhythm of a
  recurring series and its session count, the sessions with how each
  stands, the flexible picker of further sessions, the notices, the total
  of a paid series and, where the type also takes a single session, the
  link that books just the time picked.

  It renders with the moment's own assigns (`{assigns}`) plus `target`
  (the component every control targets) and, on a page that shows the
  time picker above the series, `change_time` (the `JS` command that takes
  the booker back to it, `SeriesParts.unavailable_notice/1`). It is made
  of `SeriesParts`, so its markup, test ids and `data-fact="series"` marks
  are the same in every theme; each theme styles it through `series.css` and its own
  stylesheet. `heading/1` and `next_hint/1` are the moment's heading and
  the line under a way on the booker cannot take yet, in the shared copy,
  and `can_continue?/1` says whether that way on may be taken.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SeriesParts
  alias TymeslotWeb.Themes.Shared.SeriesPicker

  @next_hint_id "series-next-hint"

  @doc """
  The moment's heading: "Book a series" for a recurring series, which
  repeats the time picked; "Choose your sessions" for a flexible one,
  naming how many when the count is fixed.
  """
  @spec heading(map() | nil) :: String.t()
  def heading(%{
        series_mode: :flexible,
        series_min_occurrences: same,
        series_max_occurrences: same
      })
      when is_integer(same),
      do:
        dngettext(
          "booking_series",
          "Choose your %{count} session",
          "Choose your %{count} sessions",
          same
        )

  def heading(%{series_mode: :flexible}), do: dgettext("booking_series", "Choose your sessions")
  def heading(_meeting_type), do: dgettext("booking_series", "Book a series")

  @doc """
  Whether a way on from the series moment may be taken: the series is
  known and no check of it is running (a known series the booker changed
  stays known while it is checked again, `Series.rechecking?/1`, but is
  not moved on from until the check answers).
  """
  @spec can_continue?(map()) :: boolean()
  def can_continue?(assigns), do: Series.known?(assigns) and assigns[:series_checking?] != true

  @doc """
  Why the booker cannot move on yet, or nil when they can (or a check is
  still answering): a flexible series short of sessions says how many to
  add; any other says every session must be available.
  """
  @spec next_hint_text(map()) :: String.t() | nil
  def next_hint_text(assigns) do
    cond do
      Series.known?(assigns) or assigns[:series_checking?] == true -> nil
      short = missing(assigns) -> short
      true -> dgettext("booking_series", "Every session must be available to continue.")
    end
  end

  @doc "The id a way on's `aria-describedby` names while `next_hint/1` shows, else nil."
  @spec next_hint_describedby(map()) :: String.t() | nil
  def next_hint_describedby(moment_assigns),
    do: if(next_hint_text(moment_assigns), do: @next_hint_id)

  @doc """
  The line under the way on, or under the sessions on a page that opens
  what follows by itself, saying why the booker cannot move on yet
  (`next_hint_text/1`); nothing once they can. Takes the moment's assigns
  (`{assigns}`).
  """
  @spec next_hint(map()) :: Phoenix.LiveView.Rendered.t()
  def next_hint(assigns) do
    assigns = assign(assigns, :hint_text, next_hint_text(assigns))

    ~H"""
    <p :if={@hint_text} id={next_hint_id()} class="series-next-hint">{@hint_text}</p>
    """
  end

  defp missing(%{
         series_choice: %{mode: :flexible, count: count},
         meeting_type: %{series_min_occurrences: min}
       })
       when is_integer(min) and count < min,
       do:
         dngettext(
           "booking_series",
           "Add at least %{count} more session to continue.",
           "Add at least %{count} more sessions to continue.",
           min - count
         )

  defp missing(_assigns), do: nil

  defp next_hint_id, do: @next_hint_id

  # No attrs declared: the moment's assigns arrive whole (`{assigns}`), as
  # `SeriesPicker.days/1` and the fact's helpers read them.
  @doc """
  The moment's body. Takes the moment's assigns (`{assigns}`) and `target`.
  """
  @spec chooser(map()) :: Phoenix.LiveView.Rendered.t()
  def chooser(assigns) do
    choice = assigns[:series_choice]
    type = assigns[:meeting_type]

    assigns =
      assign(assigns,
        choice: choice,
        mode: type && type.series_mode,
        min: type && type.series_min_occurrences,
        max: type && type.series_max_occurrences,
        rows: Series.rows(assigns),
        unavailable?: Series.unavailable(assigns) != [],
        first_start: Series.first_start(assigns)
      )

    ~H"""
    <div class="series-chooser">
      <SeriesParts.announcement rows={@rows} checking={@series_checking?} />

      <%= if @choice == :single do %>
        <div class="series-single" data-testid="series-single">
          <p class="series-single-text">
            {dgettext("booking_series", "You're booking just this session:")}
            <strong>
              {LocalizationHelpers.format_meeting_datetime_compact(@first_start, @user_timezone)}
            </strong>
          </p>
          <button
            type="button"
            class="series-link"
            phx-click="series_as_series"
            phx-target={@target}
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
          target={@target}
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
            @series_refocus and @mode == :flexible and is_map(@choice) and @choice.count >= @max
          }
          target={@target}
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
          target={@target}
        />

        <SeriesParts.check_error :if={@series_error} reason={@series_error} target={@target} />
        <SeriesParts.unavailable_notice
          :if={@unavailable?}
          target={@target}
          change_time={assigns[:change_time]}
        />

        <SeriesParts.total
          :if={!@is_rescheduling and is_map(@choice)}
          meeting_type={@meeting_type}
          currency={@host_currency}
          locale={@locale}
          count={@choice.count}
          id={nil}
        />

        <button
          :if={@series_single_allowed?}
          type="button"
          class="series-link"
          phx-click="series_single"
          phx-target={@target}
          data-testid="series-book-single"
        >
          {dgettext("booking_series", "Book just this session")}
        </button>
      <% end %>
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
end
