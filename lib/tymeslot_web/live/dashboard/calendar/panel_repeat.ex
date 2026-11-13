defmodule TymeslotWeb.Dashboard.Calendar.PanelRepeat do
  @moduledoc """
  The side panel's Repeat field: common patterns named for the event's own
  start ("Every week on Wednesday", "Every month on the second Wednesday"),
  the summary of what is set, and the repeat editor (`RecurrenceEditor`)
  behind Custom… for anything else, staged until "Save repeat".

  A preset is a canned set of the editor's fields, so a preset and a custom
  pattern become a rule the same way
  (`RepeatForm.compose_recurrence_rule/2`), anchored where the scope is
  written from: the event's own start for one event, the series' first start
  for all of a series, and where the series put this occurrence for it and
  the following ones. What the calendar would refuse is refused here, before
  anything is written (`CalendarEditMessages.repeat_refusal/1`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias Tymeslot.Integrations.Calendar.Recurrence.Series
  alias Tymeslot.Integrations.Calendar.Recurrence.Summary, as: RecurrenceSummary
  alias TymeslotWeb.Components.Calendar.RecurrenceEditor
  alias TymeslotWeb.Components.Calendar.RepeatForm
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Helpers.LocaleFormat

  @presets ~w(none daily weekdays weekly monthly yearly)
  @weekdays ~w(mo tu we th fr sa su)a

  @type spec :: {:preset, String.t()} | {:custom, map()}

  @doc "Whether `key` names a preset the field writes."
  @spec preset?(String.t()) :: boolean()
  def preset?(key), do: key in @presets

  @doc """
  What the field shows for `event`: the options, the one chosen now
  (`"keep"` for an occurrence whose row carries no rule of its own,
  `"custom"` for a rule no preset makes), the summary, and what the editor
  needs (`rule`, `start`, `timezone`). `writable` is false for a calendar
  the grid writes no repeat rules to.
  """
  @spec field(map(), String.t()) :: map()
  def field(event, user_timezone) do
    start = RepeatForm.recurrence_start(event, user_timezone)
    zone = RepeatForm.recurrence_timezone(event, user_timezone)
    rule = Map.get(event, :recurrence_rule)
    current = current(event, rule, start, zone)

    %{
      current: current,
      options: options(date_of(start), current),
      summary: summary(event, rule, start),
      rule: rule,
      start: start,
      timezone: zone,
      writable: Changes.repeatable_provider?(Map.get(event, :provider))
    }
  end

  @doc """
  What the editor's fields stage for `event`: the rule they make from the
  event's start, with why it cannot be saved (`:notice`), or `nil` when it
  is the rule the event has.
  """
  @spec stage(map(), map(), String.t()) :: map() | nil
  def stage(event, params, user_timezone) do
    start = RepeatForm.recurrence_start(event, user_timezone)
    zone = RepeatForm.recurrence_timezone(event, user_timezone)

    case compose(params, event, date_of(start), zone) do
      {:error, :until_before_start} ->
        %{
          params: params,
          rule: compose(params, event, date_of(start), zone, false),
          notice: CalendarEditMessages.repeat_refusal(:until_before_start)
        }

      rule ->
        if Pattern.equivalent?(rule, Map.get(event, :recurrence_rule), start),
          do: nil,
          else: %{params: params, rule: rule, notice: nil}
    end
  end

  @doc """
  The rule `spec` writes to `event` in `scope` (`nil` for an event of no
  series), with the write's options; `:unchanged` when the event already
  repeats that way; or why it is not written.
  """
  @spec rule_for(spec(), map(), nil | :this_only | :following | :all, String.t()) ::
          {:ok, String.t() | nil, keyword()} | :unchanged | {:error, String.t()}
  def rule_for(spec, event, scope, user_timezone) do
    zone = RepeatForm.recurrence_timezone(event, user_timezone)

    with {:ok, anchor} <- anchor(event, scope, user_timezone),
         {:ok, rule} <- rule(spec, event, date_of(anchor), zone),
         :ok <- removable(rule, scope),
         :ok <- changed(rule, event, anchor),
         :ok <- following(rule, event, scope, zone),
         nil <- Changes.repeat_refusal(Map.get(event, :provider), rule, date_of(anchor), zone) do
      {:ok, rule, write_opts(scope, zone)}
    else
      :unchanged -> :unchanged
      {:error, reason} -> {:error, CalendarEditMessages.repeat_refusal(reason)}
      reason when is_atom(reason) -> {:error, CalendarEditMessages.repeat_refusal(reason)}
    end
  end

  # A rule written to a whole series is read from its first start; one
  # written from an occurrence on, from where the series put it. A series
  # whose provider takes no scoped write (`:this_only`) cannot take a rule
  # change at all.
  defp anchor(event, nil, timezone), do: {:ok, RepeatForm.recurrence_start(event, timezone)}
  defp anchor(_event, :this_only, _timezone), do: {:error, :removal}
  defp anchor(event, :all, timezone), do: in_zone(Changes.series_start(event), event, timezone)

  defp anchor(event, :following, timezone),
    do: in_zone(Changes.occurrence_slot(event), event, timezone)

  defp in_zone(nil, _event, _timezone), do: {:error, :start_unknown}

  defp in_zone(start, event, timezone),
    do: {:ok, RepeatForm.in_recurrence_zone(start, event, timezone)}

  defp rule({:preset, key}, event, date, zone),
    do: rule({:custom, preset_params(key, date)}, event, date, zone)

  defp rule({:custom, params}, event, date, zone) do
    case compose(params, event, date, zone) do
      {:error, reason} -> {:error, reason}
      rule -> {:ok, rule}
    end
  end

  defp removable(nil, scope) when scope != nil, do: {:error, :removal}
  defp removable(_rule, _scope), do: :ok

  defp changed(rule, event, anchor) do
    if Pattern.equivalent?(rule, Map.get(event, :recurrence_rule), anchor),
      do: :unchanged,
      else: :ok
  end

  defp following(rule, event, :following, zone) do
    case Changes.following_rule(event, rule, zone) do
      {:ok, _left} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp following(_rule, _event, _scope, _zone), do: :ok

  # A one-off given a rule is written in the event's own zone (a CalDAV
  # series keeps its local time across a clock change); a series' writers
  # read the new end date back in the zone it ended its day in.
  defp write_opts(nil, zone), do: [timezone: zone]
  defp write_opts(_series_scope, zone), do: [until_timezone: zone]

  defp compose(params, event, date, zone, check_until \\ true) do
    RepeatForm.compose_recurrence_rule(params, %{
      all_day: Map.get(event, :all_day, false),
      start_date: date,
      timezone: zone,
      rule: Map.get(event, :recurrence_rule),
      check_until: check_until
    })
  end

  defp preset_params("none", _date), do: %{}
  defp preset_params("daily", _date), do: %{"freq" => "daily"}
  defp preset_params("weekdays", _date), do: %{"freq" => "weekly", "by_day" => ~w(mo tu we th fr)}
  defp preset_params("weekly", _date), do: %{"freq" => "weekly"}

  defp preset_params("monthly", date) do
    {ordinal, weekday} = nth_weekday(date)
    %{"freq" => "monthly", "on" => "#{ordinal}:#{weekday}"}
  end

  defp preset_params("yearly", _date), do: %{"freq" => "yearly"}

  # The start's place among the month's days of its weekday: the second
  # Wednesday, or the last when it is the fifth (`Pattern.choices/1`).
  defp nth_weekday(date) do
    weekday = Enum.at(@weekdays, Date.day_of_week(date) - 1)
    Enum.find(Pattern.choices(date), &match?({_ordinal, ^weekday}, &1))
  end

  defp current(event, rule, _start, _zone) when rule in [nil, ""] do
    if Series.member?(event), do: "keep", else: "none"
  end

  defp current(event, rule, start, zone) do
    date = date_of(start)

    Enum.find(offered(date) -- ["none"], "custom", fn key ->
      Pattern.equivalent?(rule, compose(preset_params(key, date), event, date, zone), start)
    end)
  end

  # Every weekday is offered only for a start on a weekday, which a weekly
  # pattern always includes.
  defp offered(date) do
    if Date.day_of_week(date) <= 5, do: @presets, else: @presets -- ["weekdays"]
  end

  defp options(date, current) do
    labels = %{
      "none" => dgettext("dashboard_calendar_editing", "Does not repeat"),
      "daily" => dgettext("dashboard_calendar_editing", "Every day"),
      "weekdays" => dgettext("dashboard_calendar_editing", "Every weekday"),
      "weekly" =>
        dgettext("dashboard_calendar_editing", "Every week on %{day}", day: weekday_name(date)),
      "monthly" =>
        dgettext("dashboard_calendar_editing", "Every month %{on}",
          on: RecurrenceSummary.on_phrase(nth_weekday(date), :monthly, date)
        ),
      "yearly" =>
        dgettext("dashboard_calendar_editing", "Every year %{on}",
          on: RecurrenceSummary.on_phrase(:day, :yearly, date)
        )
    }

    presets = for key <- offered(date), do: {Map.fetch!(labels, key), key}
    custom = [{dgettext("dashboard_calendar_editing", "Custom…"), "custom"}]

    keep =
      if current == "keep",
        do: [{dgettext("dashboard_calendar_editing", "Repeats"), "keep"}],
        else: []

    keep ++ presets ++ custom
  end

  defp summary(event, rule, start) do
    if rule in [nil, ""] and Series.member?(event),
      do: dgettext("dashboard_calendar_editing", "Repeats"),
      else: RecurrenceEditor.summary(rule, start)
  end

  defp weekday_name(date),
    do:
      LocaleFormat.format_weekday_name(
        Date.day_of_week(date),
        Gettext.get_locale(TymeslotWeb.Gettext),
        :full
      )

  defp date_of(%DateTime{} = at), do: DateTime.to_date(at)
  defp date_of(%Date{} = date), do: date

  attr :repeat, :map, required: true
  attr :disabled, :boolean, default: false
  attr :custom_open, :boolean, default: false
  attr :draft, :map, default: nil
  attr :version, :integer, default: 0
  attr :target, :any, required: true

  @doc "The Repeat select, its summary, and the custom editor behind Custom…."
  @spec repeat_field(map()) :: Phoenix.LiveView.Rendered.t()
  def repeat_field(assigns) do
    ~H"""
    <div class="space-y-1">
      <form id="calendar-panel-repeat" phx-change="panel:repeat" phx-target={@target} novalidate>
        <%!-- A new id draws the select again, with the server's value. --%>
        <div id={"calendar-panel-repeat-field-#{@version}"}>
          <.select
            id="calendar-panel-repeat-preset"
            name="preset"
            label={dgettext("dashboard_calendar_editing", "Repeat")}
            value={@repeat.current}
            options={@repeat.options}
            disabled={@disabled or not @repeat.writable}
          />
        </div>
      </form>
      <p
        :if={@repeat.summary}
        id="calendar-panel-repeat-summary"
        class="text-token-xs text-tymeslot-500"
      >
        {@repeat.summary}
      </p>
      <p :if={not @repeat.writable} class="text-token-xs text-tymeslot-500">
        {CalendarEditMessages.repeat_refusal(:not_supported)}
      </p>
      <button
        :if={@repeat.current == "custom" and not @disabled and @repeat.writable}
        type="button"
        id="calendar-panel-repeat-toggle"
        aria-expanded={to_string(@custom_open)}
        aria-controls="calendar-panel-repeat-custom"
        phx-click="panel:repeat_toggle"
        phx-target={@target}
        class="text-token-xs font-semibold text-turquoise-700 hover:text-turquoise-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
      >
        {if @custom_open,
          do: dgettext("dashboard_calendar_editing", "Hide custom pattern"),
          else: dgettext("dashboard_calendar_editing", "Edit custom pattern")}
      </button>
      <div :if={@custom_open} id="calendar-panel-repeat-custom">
        <RecurrenceEditor.recurrence_editor
          recurrence_rule={if @draft, do: @draft.rule, else: @repeat.rule}
          timezone={@repeat.timezone}
          start={@repeat.start}
          myself={@target}
          key="panel-repeat"
          change_event="panel:repeat_custom"
          pending={@draft != nil}
          save_event="panel:repeat_save"
          discard_event="panel:repeat_discard"
          save_blocked={@draft != nil and @draft.notice != nil}
          notice={@draft && @draft.notice}
        />
      </div>
    </div>
    """
  end
end
