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
      lists a day's times.
    * `:slow` and `:failed`: like `:placeholder`, with the line saying the
      free times will appear on the page.

  The times enter with the reveal animation (`onboarding.css`) when
  `reveal` is set, which the caller does only on the render where the week
  changed, so a later re-render never replays it.
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
          narrow: String.t(),
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
          agenda: [entry()],
          month: map()
        }

  @doc "The week the stage starts with: no calendar yet."
  @spec placeholder() :: week()
  def placeholder, do: %{state: :placeholder, preview: nil}

  @doc """
  The view every theme lays out, for `week` as of `today` (in the host's
  timezone), worded in `locale`.
  """
  @spec view(week() | nil, Date.t(), String.t()) :: t()
  def view(week, today, locale) do
    week = week || placeholder()
    ready? = week.state == :ready and match?(%WeekPreview{}, week.preview)
    days = days(week, ready?, today, locale)
    selected = if ready?, do: Enum.find(days, & &1.open?)

    %{
      state: week.state,
      ready?: ready?,
      message: message(week.state, ready?),
      days: days,
      selected: selected,
      heading: LocaleFormat.format_weekday_day_month((selected || hd(days)).date, locale),
      day_note: day_note(selected),
      agenda: agenda(selected, locale),
      month: month(days, selected, ready?, today, locale)
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
      narrow: LocaleFormat.format_weekday_name(weekday, locale, :narrow),
      number: date.day,
      slots: Enum.map(slots, &format_label(&1, locale)),
      starts: Enum.map(slots, &parse_label/1),
      busy: busy,
      open?: slots != []
    }
  end

  defp day_note(nil), do: nil

  defp day_note(%{slots: slots}) do
    dngettext("onboarding_wizard", "%{count} free time", "%{count} free times", length(slots))
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

  # The weeks around the coming seven days, Monday first, as a month
  # calendar shows them.
  defp month(days, selected, ready?, today, locale) do
    by_date = Map.new(days, &{&1.date, &1})
    first = Date.beginning_of_week(today)

    %{
      title: LocaleFormat.format_month_year(today.month, today.year, locale),
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

  defp message(_state, true), do: nil

  defp message(:loading, _ready?), do: dgettext("onboarding_wizard", "Reading your calendar…")

  defp message(state, _ready?) when state in [:slow, :failed],
    do: dgettext("onboarding_wizard", "Connected. Your free times will appear on your page.")

  defp message(_state, _ready?),
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
  attr :highlighted, :boolean, default: false

  @doc """
  A month calendar of the two weeks around the coming seven days, with real
  day numbers: days with times in the primary's tint, the chosen day solid,
  days without times struck through, the rest faint.
  """
  @spec month_grid(map()) :: Phoenix.LiveView.Rendered.t()
  def month_grid(assigns) do
    ~H"""
    <div class="w-full flex flex-col gap-1" data-preview-part="month">
      <p
        class="text-token-xs font-semibold text-left"
        style={"color: #{PreviewParts.color(@colors, :text, "#0f172a")};"}
      >
        {@view.month.title}
      </p>
      <div class="grid grid-cols-7 gap-1">
        <span
          :for={name <- @view.month.weekdays}
          class="text-token-2xs font-semibold text-center"
          style={"color: #{PreviewParts.color(@colors, :text_secondary, "#475569")};"}
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

  attr :view, :map, required: true
  attr :colors, :map, required: true
  attr :layout, :atom, values: [:chips, :rows], required: true
  attr :limit, :integer, default: 6
  attr :class, :string, default: nil, doc: "the list's own layout (columns, gaps)"
  attr :item_class, :string, default: "rounded-token-md"
  attr :reveal, :boolean, default: false

  @doc """
  The chosen day's times, or the week's line where there are none to show.

  `:chips` lists the free times alone, as a month-grid theme shows them
  under its calendar; `:rows` lists the day in time order with its busy
  blocks hatched between the free times, as a day view does.
  """
  @spec times(map()) :: Phoenix.LiveView.Rendered.t()
  def times(%{view: %{ready?: true}} = assigns) do
    assigns = assign(assigns, :entries, entries(assigns))

    ~H"""
    <div class={["w-full", @class]} data-preview-part="times" data-reveal={@reveal}>
      <span
        :for={{entry, index} <- Enum.with_index(@entries)}
        class={[
          "text-token-xs font-medium inline-flex items-center",
          @layout == :chips && "justify-center px-2 py-1.5",
          @layout == :rows && "w-full gap-1.5 px-3 py-2",
          entry.kind == :busy && "onboarding-preview-busy",
          @item_class
        ]}
        style={entry_style(@colors, entry.kind, index)}
        data-reveal-item={entry.kind == :slot}
        data-entry={entry.kind}
      >
        {entry.label}
      </span>
    </div>
    """
  end

  def times(assigns) do
    ~H"""
    <div class="w-full flex flex-col items-center gap-2" data-preview-part="times">
      <div :if={@view.state == :loading} class="w-full grid grid-cols-3 gap-1.5" aria-hidden="true">
        <span
          :for={_n <- 1..3}
          class={["h-6 onboarding-preview-shimmer", @item_class]}
          style={"color: #{PreviewParts.color(@colors, :text_secondary, "#475569")};"}
        />
      </div>
      <p
        class="text-token-xs text-center leading-snug"
        style={"color: #{PreviewParts.color(@colors, :text_secondary, "#475569")};"}
        data-role="week-message"
      >
        {@view.message}
      </p>
    </div>
    """
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

  defp cell_style(colors, :selected) do
    "background: #{PreviewParts.color(colors, :primary, "#14b8a6")};color: #ffffff;"
  end

  defp cell_style(colors, :open) do
    primary = PreviewParts.color(colors, :primary, "#14b8a6")
    "background: #{primary}26;color: #{PreviewParts.color(colors, :text, "#0f172a")};"
  end

  defp cell_style(colors, :idle) do
    muted = PreviewParts.color(colors, :text_secondary, "#475569")
    "background: #{muted}14;color: #{muted};"
  end

  defp cell_style(colors, :closed) do
    "color: #{PreviewParts.color(colors, :text_secondary, "#475569")};opacity: 0.55;"
  end

  defp cell_style(colors, :outside) do
    "color: #{PreviewParts.color(colors, :text_secondary, "#475569")};opacity: 0.3;"
  end

  defp entry_style(colors, :slot, index) do
    primary = PreviewParts.color(colors, :primary, "#14b8a6")

    "background: #{primary}1f;color: #{PreviewParts.color(colors, :text, "#0f172a")};" <>
      "--reveal-index: #{index};"
  end

  defp entry_style(colors, :busy, _index) do
    muted = PreviewParts.color(colors, :text_secondary, "#475569")
    "color: #{muted};background-color: #{muted}0f;"
  end
end
