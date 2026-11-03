defmodule TymeslotWeb.OnboardingLive.PreviewWeek do
  @moduledoc """
  The host's coming week as the onboarding previews draw it.

  Every theme's `onboarding_preview/1` shows the same facts in its own
  shape, so what those facts are is decided once, here: `view/3` turns the
  stage's week (`%{state: atom(), preview: WeekPreview.t() | nil}`, the
  wizard's `@stage_week`) into a view of real dates, slot labels and busy
  blocks, formatted in the host's locale, and the components below lay its
  parts out. A theme picks which parts it shows (a month grid, a week strip,
  a list of times) and how they look; it never decides what a state means.

  What each state shows:

    * `:placeholder`: the real coming week in muted colours, no times, and
      the line telling the host their free times appear once a calendar is
      connected.
    * `:loading`: the same, with a shimmer where the times will be and the
      line saying the calendar is being read.
    * `:ready`: the week from the preview: days without times read as
      unavailable, the first day with times is chosen and its times shown,
      and busy blocks are drawn hatched in the muted colour wherever a theme
      lists a day's times. A week with no free time at all says so instead.
    * `:slow` and `:failed`: like `:placeholder`, with the line saying the
      free times will appear on the page.

  The times enter with the reveal animation (`onboarding.css`) when their
  list is new in the page. The list's id (`times_id`) carries the stage's
  `reveal_key`, so a new week (a bumped key) replaces the list and reveals
  it once, while any other re-render, or a reconnect, patches the same list
  in place and never replays or cuts it short.

  Every date is the preview's own: before the week is ready, the coming
  seven days from `today`; once it is, the preview's days, so a page left
  open past midnight still shows the week it was given.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.WeekPreview
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.OnboardingLive.PreviewParts

  @days 7

  @type state :: :placeholder | :loading | :ready | :slow | :failed
  @type week :: %{state: state(), preview: WeekPreview.t() | nil}

  @type day :: %{
          date: Date.t(),
          weekday: String.t(),
          number: pos_integer(),
          slots: [String.t()],
          starts: [Time.t()],
          busy: [{Time.t(), Time.t()}],
          open?: boolean()
        }

  @type entry :: %{kind: :slot | :busy, label: String.t(), at: Time.t()}

  @type t :: %{
          state: state(),
          ready?: boolean(),
          message: String.t() | nil,
          days: [day()],
          selected: day() | nil,
          heading: String.t(),
          day_note: String.t() | nil,
          times_id: String.t(),
          agenda: [entry()],
          month: map()
        }

  @doc "The week the stage starts with: no calendar yet."
  @spec placeholder() :: week()
  def placeholder, do: %{state: :placeholder, preview: nil}

  @doc """
  The view every theme lays out, for `week` as of `today` (the host's date,
  `Tymeslot.Availability.today/1`), worded in `locale`.

  Options: `:id`, what the stage copy is called (the stage and its expanded
  copy each pass their own, so their ids never clash), and `:reveal_key`,
  the stage's count of weeks shown; together they make `times_id`.
  """
  @spec view(week() | nil, Date.t(), String.t(), keyword()) :: t()
  def view(week, %Date{} = today, locale, opts \\ []) do
    week = week || placeholder()
    ready? = week.state == :ready and match?(%WeekPreview{}, week.preview)
    days = days(week, ready?, today, locale)
    selected = if ready?, do: Enum.find(days, & &1.open?)
    shown = selected || hd(days)

    %{
      state: week.state,
      ready?: ready?,
      message: message(week.state, ready?, selected),
      days: days,
      selected: selected,
      heading: LocaleFormat.format_weekday_day_month(shown.date, locale),
      day_note: day_note(ready?, selected),
      times_id: "#{Keyword.get(opts, :id, "preview")}-times-#{Keyword.get(opts, :reveal_key, 0)}",
      agenda: agenda(selected, locale),
      month: month(days, selected, shown, ready?, locale)
    }
  end

  @doc "The selected day's entries, at most `limit`, keeping the first busy block in view."
  @spec agenda_window([entry()], pos_integer()) :: [entry()]
  def agenda_window(agenda, limit) do
    case Enum.find_index(agenda, &(&1.kind == :busy)) do
      index when is_integer(index) and index >= limit ->
        Enum.slice(agenda, index - limit + 2, limit)

      _none_or_in_view ->
        Enum.take(agenda, limit)
    end
  end

  # -------------------------------------------------------------------
  # View model
  # -------------------------------------------------------------------

  defp days(%{preview: %WeekPreview{days: days}}, true, _today, locale) do
    Enum.map(days, &day(&1.date, &1.slots, &1.busy, locale))
  end

  defp days(_week, false, today, locale) do
    for offset <- 0..(@days - 1), do: day(Date.add(today, offset), [], [], locale)
  end

  defp day(date, slots, busy, locale) do
    weekday = Date.day_of_week(date)

    %{
      date: date,
      weekday: LocaleFormat.format_weekday_name(weekday, locale, :short),
      number: date.day,
      slots: Enum.map(slots, &format_label(&1, locale)),
      starts: Enum.map(slots, &parse_label/1),
      busy: busy,
      open?: slots != []
    }
  end

  # Before the week is ready there is no count to give; a ready week with
  # no free day counts none.
  defp day_note(false, _selected), do: nil
  defp day_note(true, selected), do: free_times(if(selected, do: length(selected.slots), else: 0))

  defp free_times(count) do
    dngettext("onboarding_wizard", "%{count} free time", "%{count} free times", count)
  end

  defp agenda(nil, _locale), do: []

  defp agenda(day, locale) do
    slots =
      for {label, at} <- Enum.zip(day.slots, day.starts), do: %{kind: :slot, label: label, at: at}

    busy =
      for {from, to} <- day.busy do
        %{
          kind: :busy,
          label:
            LocaleFormat.format_time(from, locale) <>
              " – " <>
              LocaleFormat.format_time(to, locale),
          at: from
        }
      end

    Enum.sort_by(slots ++ busy, & &1.at, Time)
  end

  # The two weeks around the seven days shown, Monday first, as a month
  # calendar shows them, titled with the month of the day it opens on.
  defp month(days, selected, shown, ready?, locale) do
    by_date = Map.new(days, &{&1.date, &1})
    first = days |> hd() |> Map.fetch!(:date) |> Date.beginning_of_week()

    %{
      title: LocaleFormat.format_month_year(shown.date.month, shown.date.year, locale),
      weekdays: for(n <- 1..7, do: LocaleFormat.format_weekday_name(n, locale, :narrow)),
      cells:
        for offset <- 0..13 do
          date = Date.add(first, offset)
          %{number: date.day, kind: cell_kind(Map.get(by_date, date), selected, ready?)}
        end
    }
  end

  defp cell_kind(nil, _selected, _ready?), do: :outside
  defp cell_kind(_day, _selected, false), do: :idle
  defp cell_kind(%{date: date}, %{date: date}, true), do: :selected
  defp cell_kind(%{open?: true}, _selected, true), do: :open
  defp cell_kind(_day, _selected, true), do: :closed

  defp message(_state, true, nil),
    do: dgettext("onboarding_wizard", "No free times in the next seven days.")

  defp message(_state, true, _selected), do: nil

  defp message(:loading, _ready?, _selected),
    do: dgettext("onboarding_wizard", "Reading your calendar…")

  defp message(state, _ready?, _selected) when state in [:slow, :failed],
    do: dgettext("onboarding_wizard", "Connected. Your free times will appear on your page.")

  defp message(_state, _ready?, _selected),
    do:
      dgettext(
        "onboarding_wizard",
        "Your free times appear here once your calendar is connected."
      )

  defp parse_label(label), do: Time.from_iso8601!(label <> ":00")
  defp format_label(label, locale), do: label |> parse_label() |> LocaleFormat.format_time(locale)

  # -------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------

  attr :view, :map, required: true
  attr :colors, :map, required: true
  attr :cell_class, :string, default: "rounded-token-sm"

  @doc """
  A month calendar of the two weeks around the coming seven days, with real
  day numbers: days with times in the primary's tint, the chosen day solid,
  days in the seven without times struck through, and the days around them
  as plain numbers.
  """
  @spec month_grid(map()) :: Phoenix.LiveView.Rendered.t()
  def month_grid(assigns) do
    ~H"""
    <div class="w-full flex flex-col gap-1" data-preview-part="month">
      <p
        class="text-token-xs font-semibold text-left"
        style={"color: #{ink(@colors)};"}
      >
        {@view.month.title}
      </p>
      <div class="grid grid-cols-7 gap-1">
        <span
          :for={name <- @view.month.weekdays}
          class="text-token-2xs font-semibold text-center"
          style={"color: #{muted(@colors)};"}
        >
          {name}
        </span>
        <span
          :for={cell <- @view.month.cells}
          class={[
            "aspect-square inline-flex items-center justify-center text-token-2xs font-medium",
            @cell_class,
            cell.kind == :closed && "line-through"
          ]}
          style={cell_style(@colors, cell.kind)}
          data-day-state={cell.kind}
        >
          {cell.number}
        </span>
      </div>
    </div>
    """
  end

  attr :view, :map, required: true
  attr :colors, :map, required: true
  attr :cell_class, :string, default: "rounded-token-md"

  @doc """
  The coming seven days as a strip of day names and numbers, the chosen day
  solid and days without times faint.
  """
  @spec day_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def day_strip(assigns) do
    ~H"""
    <div class="w-full flex justify-between gap-1" data-preview-part="days">
      <span
        :for={day <- @view.days}
        class={[
          "grow basis-0 py-1 inline-flex flex-col items-center justify-center leading-tight",
          @cell_class
        ]}
        style={cell_style(@colors, strip_kind(day, @view))}
        data-day-state={strip_kind(day, @view)}
      >
        <span class="text-token-2xs font-medium">{day.weekday}</span>
        <span class="text-token-xs font-bold">{day.number}</span>
      </span>
    </div>
    """
  end

  attr :colors, :map, required: true
  attr :highlight, :list, default: [], doc: "the regions ringed for the step"
  attr :class, :string, default: "flex flex-col gap-3"
  attr :rest, :global
  slot :inner_block, required: true

  @doc """
  The theme's calendar area: its days and its times. Ringed, and marked as
  what the stage brings into view on a phone (`data-stage-focus`), on the
  step that highlights it.
  """
  @spec calendar_area(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_area(assigns) do
    ~H"""
    <div
      class={["w-full rounded-token-lg", @class]}
      style={PreviewParts.ring(:calendar in @highlight, @colors)}
      data-preview-region="calendar"
      data-stage-focus={:calendar in @highlight}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :view, :map, required: true
  attr :colors, :map, required: true
  attr :layout, :atom, values: [:chips, :rows], required: true
  attr :limit, :integer, default: 6
  attr :class, :string, default: nil, doc: "the list's own layout (columns, gaps)"
  attr :item_class, :string, default: "rounded-token-md"
  attr :highlight, :list, default: [], doc: "the regions ringed for the step"

  @doc """
  The chosen day's times, or the week's line where there are none to show.

  `:chips` lists the free times alone, as a month-grid theme shows them
  under its calendar; `:rows` lists the day in time order with its busy
  blocks hatched between the free times, as a day view does.

  It always draws `limit` cells, so it is the same height in every state
  and nothing below it moves when the week arrives: a day with fewer
  entries is padded with blank cells, and before the week is ready the
  cells are faint (shimmering while the calendar is read) under the week's
  line.
  """
  @spec times(map()) :: Phoenix.LiveView.Rendered.t()
  def times(assigns) do
    assigns =
      assign(assigns,
        cells: cells(assigns),
        highlighted: :slots in assigns.highlight
      )

    ~H"""
    <div
      id={@view.times_id}
      class="relative w-full rounded-token-lg"
      style={PreviewParts.ring(@highlighted, @colors)}
      data-preview-part="times"
      data-preview-region="slots"
      data-stage-focus={@highlighted}
      data-week-state={@view.state}
      data-reveal
    >
      <div class={["w-full", @class]}>
        <span
          :for={{cell, index} <- Enum.with_index(@cells)}
          class={[
            "text-token-xs font-medium inline-flex items-center",
            @layout == :chips && "justify-center px-2 py-1.5",
            @layout == :rows && "w-full gap-1.5 px-3 py-2",
            cell.kind == :busy && "onboarding-preview-busy",
            cell.kind == :loading && "onboarding-preview-shimmer",
            cell.kind == :filler && "invisible",
            @item_class
          ]}
          style={cell_style(@colors, cell.kind, index)}
          data-reveal-item={cell.kind == :slot}
          data-entry={cell.kind in [:slot, :busy] && cell.kind}
        >
          {cell.label}
        </span>
      </div>
      <p
        :if={@view.message}
        class="absolute inset-0 flex items-center justify-center px-3 text-token-xs text-center leading-snug"
        style={"color: #{muted(@colors)};"}
        data-role="week-message"
      >
        {@view.message}
      </p>
    </div>
    """
  end

  # Exactly `limit` cells: the chosen day's entries, then blanks; with no
  # day to show (before the week is ready, or a week with no free time),
  # faint cells, shimmering while it loads. A blank keeps a line's height
  # with a no-break space.
  defp cells(%{view: %{selected: %{}}} = assigns) do
    entries = entries(assigns)
    entries ++ List.duplicate(%{kind: :filler, label: "\u00a0"}, assigns.limit - length(entries))
  end

  defp cells(%{view: view, limit: limit}) do
    kind = if view.state == :loading, do: :loading, else: :ghost
    List.duplicate(%{kind: kind, label: "\u00a0"}, limit)
  end

  defp entries(%{layout: :chips, view: view, limit: limit}) do
    view.agenda |> Enum.filter(&(&1.kind == :slot)) |> Enum.take(limit)
  end

  defp entries(%{layout: :rows, view: view, limit: limit}),
    do: agenda_window(view.agenda, limit)

  defp strip_kind(_day, %{ready?: false}), do: :idle
  defp strip_kind(%{date: date}, %{selected: %{date: date}}), do: :selected
  defp strip_kind(%{open?: true}, _view), do: :open
  defp strip_kind(_day, _view), do: :closed

  # -------------------------------------------------------------------
  # Styles (per-user colours)
  # -------------------------------------------------------------------

  defp cell_style(colors, :selected), do: "background: #{primary(colors)};color: #ffffff;"
  defp cell_style(colors, :open), do: "background: #{primary(colors)}26;color: #{ink(colors)};"
  defp cell_style(colors, :idle), do: "background: #{muted(colors)}14;color: #{muted(colors)};"
  defp cell_style(colors, :closed), do: "color: #{muted(colors)};opacity: 0.55;"
  # A day outside the seven shown is neither free nor taken: a plain number.
  defp cell_style(colors, :outside), do: "color: #{muted(colors)};"

  defp cell_style(colors, :slot, index),
    do: "background: #{primary(colors)}1f;color: #{ink(colors)};--reveal-index: #{index};"

  defp cell_style(colors, :busy, _index),
    do: "color: #{muted(colors)};background-color: #{muted(colors)}0f;"

  defp cell_style(colors, :ghost, _index), do: "background-color: #{muted(colors)}0a;"
  defp cell_style(colors, :loading, _index), do: "color: #{muted(colors)};"
  defp cell_style(_colors, :filler, _index), do: nil

  # The theme's colours, or the neutral defaults where it sets none.
  defp primary(colors), do: PreviewParts.color(colors, :primary, "#14b8a6")
  defp ink(colors), do: PreviewParts.color(colors, :text, "#0f172a")
  defp muted(colors), do: PreviewParts.color(colors, :text_secondary, "#475569")
end
