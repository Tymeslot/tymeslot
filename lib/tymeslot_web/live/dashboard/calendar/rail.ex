defmodule TymeslotWeb.Dashboard.Calendar.Rail do
  @moduledoc """
  The collapsible left rail of the calendar surface: a mini-month of the
  visible range, then the organiser's calendars grouped by account, each with
  a colour checkbox, a lock when Tymeslot cannot write to it, an eye when
  it is shown but does not block bookings ("Doesn't block", spelt out in
  the Calendars sheet), and its sync status: a spinner while it syncs, a
  warning while it has a problem (explained in the banner), and Sync now. With no calendar connected it
  says that bookings and bookable times still show, and links to connecting
  one.

  Under the calendars, Layers: the bookable-times switch and the meeting
  type it shows (see `RailLayers`). Under the mini month, calendar sets
  (see `RailSets`): saved groups of calendars, each applied by its digit.
  At its foot, the organiser's time zone (`ZoneLink`), which every time is
  shown in.
  Below 768px the rail is hidden; its calendars and layers open in the
  Calendars sheet (`CalendarsSheet`), from the toolbar or the phone header,
  and B still works.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Calendar.CalendarColourPicker
  alias TymeslotWeb.Dashboard.Calendar.MiniMonth
  alias TymeslotWeb.Dashboard.Calendar.RailLayers
  alias TymeslotWeb.Dashboard.Calendar.RailSets
  alias TymeslotWeb.Dashboard.Calendar.ZoneLink

  attr :accounts, :list, required: true
  attr :syncing_ids, :any, default: MapSet.new()
  attr :problem_ids, :any, default: MapSet.new()
  attr :reauth_ids, :any, default: MapSet.new()
  attr :mini_cursor, :any, required: true
  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :days, :list, required: true
  attr :today, :any, required: true
  attr :week_start, :atom, required: true
  attr :locale, :string, required: true
  attr :bookable, :map, required: true, doc: "see `LayerChoices.rail/2`"
  attr :colours, :map, default: %{keys: %{}, open: nil}, doc: "see `calendar_list/1`"
  attr :set_view, :map, required: true, doc: "see `RailSets.view/1`"
  attr :target, :any, required: true
  attr :week_numbers, :boolean, default: false
  attr :timezone, :string, required: true, doc: "the zone the surface reads times in"

  @spec rail(map()) :: Phoenix.LiveView.Rendered.t()
  def rail(assigns) do
    ~H"""
    <aside
      id="calendar-rail"
      class="hidden w-60 shrink-0 flex-col gap-5 overflow-y-auto border-r border-tymeslot-200 bg-white p-3 md:flex"
      aria-label={dgettext("dashboard_calendar", "Calendars")}
    >
      <MiniMonth.mini_month
        id="calendar-rail-month"
        cursor={@mini_cursor}
        view={@view}
        date={@date}
        days={@days}
        today={@today}
        week_start={@week_start}
        locale={@locale}
        target={@target}
        week_numbers={@week_numbers}
      />
      <RailSets.sets
        sets={@set_view.sets}
        active_position={@set_view.active_position}
        editor={@set_view.editor}
        target={@target}
      />
      <.calendar_list
        accounts={@accounts}
        syncing_ids={@syncing_ids}
        problem_ids={@problem_ids}
        reauth_ids={@reauth_ids}
        set_active={not is_nil(@set_view.name)}
        colours={@colours}
        target={@target}
      />
      <RailLayers.layers bookable={@bookable} target={@target} />
      <ZoneLink.zone_link
        id="calendar-rail-timezone"
        timezone={@timezone}
        class="sticky bottom-0 -mx-3 -mb-3 mt-auto border-t border-tymeslot-200 bg-white px-4"
      />
    </aside>
    """
  end

  @doc """
  The calendars grouped by account, as the rail shows them; the Calendars
  sheet shows the same list. `id_prefix` keeps the two copies' ids apart:
  the rail's default keeps the ids it has always had.
  """
  attr :id_prefix, :string, default: "calendar-rail"

  attr :accounts, :list, required: true
  attr :syncing_ids, :any, default: MapSet.new()
  attr :problem_ids, :any, default: MapSet.new()
  attr :reauth_ids, :any, default: MapSet.new()

  attr :set_active, :boolean, default: false, doc: "a set is active: ticks edit it"

  attr :colours, :map,
    default: %{keys: %{}, open: nil},
    doc:
      "each calendar's stored palette key (`keys`, by `{integration id, calendar id}`) and the calendar whose palette is open (`open`), see `CalendarColours`"

  attr :spell_out, :boolean,
    default: false,
    doc:
      ~s(spell out "Doesn't block" where there is room; the rail shows its icon, named by the words)

  attr :target, :any, required: true

  @spec calendar_list(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_list(assigns) do
    ~H"""
    <section aria-labelledby={"#{@id_prefix}-heading"}>
      <h2
        id={"#{@id_prefix}-heading"}
        class="mb-2 text-token-xs font-semibold uppercase tracking-wide text-tymeslot-500"
      >
        {dgettext("dashboard_calendar", "Calendars")}
      </h2>
      <div :if={@accounts == []} id={"#{@id_prefix}-connect"} class="space-y-2">
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_calendar_booking",
            "No calendar connected. Your bookings and bookable times still show here."
          )}
        </p>
        <.action_link
          id={connect_link_id(@id_prefix)}
          patch={~p"/dashboard/integrations?tab=calendars"}
          variant={:secondary}
          size={:sm}
          icon="hero-plus"
        >
          {dgettext("dashboard_calendar_booking", "Connect a calendar")}
        </.action_link>
      </div>
      <div
        :for={account <- @accounts}
        id={item_id(@id_prefix, "account-#{account.id}")}
        class="mb-3 last:mb-0"
      >
        <div class="flex items-center gap-2 py-1">
          <.check
            checked={not account.hidden}
            colour={account.colour}
            label={account.name}
            event="calendar:toggle_account"
            values={%{"integration-id" => account.id}}
            data={[{"data-account-id", account.id}]}
            target={@target}
          />
          <span
            id={item_id(@id_prefix, "account-#{account.id}-name")}
            class="min-w-0 flex-1 truncate text-token-sm font-semibold text-tymeslot-800"
          >
            {account.name}
          </span>
          <.lock :if={account.read_only} label={dgettext("dashboard_calendar", "Read only")} />
          <.tooltip
            :if={MapSet.member?(@syncing_ids, account.id)}
            text={dgettext("dashboard_calendar", "Syncing")}
          >
            <span data-syncing class="shrink-0 text-tymeslot-400">
              <.icon name="hero-arrow-path-mini" class="h-4 w-4 motion-safe:animate-spin" />
              <span class="sr-only">{dgettext("dashboard_calendar", "Syncing")}</span>
            </span>
          </.tooltip>
          <.tooltip
            :if={MapSet.member?(@problem_ids, account.id)}
            text={dgettext("dashboard_calendar", "Sync problem")}
          >
            <span data-sync-problem class="shrink-0 text-amber-600">
              <.icon name="hero-exclamation-triangle-mini" class="h-4 w-4" />
              <span class="sr-only">{dgettext("dashboard_calendar", "Sync problem")}</span>
            </span>
          </.tooltip>
          <.icon_button
            :if={
              not MapSet.member?(@syncing_ids, account.id) and
                not MapSet.member?(@reauth_ids, account.id)
            }
            id={item_id(@id_prefix, "sync-#{account.id}")}
            icon="hero-arrow-path"
            size={:sm}
            label={dgettext("dashboard_calendar", "Sync %{account} now", account: account.name)}
            phx-click="calendar:sync_account"
            phx-value-integration-id={account.id}
            phx-target={@target}
          />
        </div>
        <ul
          role="group"
          aria-labelledby={item_id(@id_prefix, "account-#{account.id}-name")}
          class={["ml-6 space-y-0.5", account.hidden && "opacity-60"]}
        >
          <li
            :for={calendar <- account.calendars}
            data-calendar-row={calendar.id}
            class="flex flex-wrap items-center gap-x-2 py-0.5"
          >
            <.check
              checked={not calendar.hidden}
              disabled={account.hidden and not @set_active}
              disabled_reason={
                dgettext("dashboard_calendar", "Show %{account} first to choose its calendars.",
                  account: account.name
                )
              }
              reason_id={row_id(@id_prefix, account, calendar, "hidden-account")}
              colour={calendar.colour}
              label={calendar.name}
              described_by={described_by(@id_prefix, account, calendar)}
              event="calendar:toggle_calendar"
              values={%{"integration-id" => account.id, "calendar-id" => calendar.id}}
              data={[{"data-calendar-id", calendar.id}]}
              target={@target}
            />
            <span class="min-w-0 flex-1 truncate text-token-sm text-tymeslot-700">{calendar.name}</span>
            <%!-- So an event shown here is not taken for a conflict: its
                 calendar is shown but takes no slots. --%>
            <.not_blocking
              :if={not calendar.blocks}
              id={row_id(@id_prefix, account, calendar, "not-blocking")}
              spell_out={@spell_out}
            />
            <.lock
              :if={calendar.read_only and not account.read_only}
              id={row_id(@id_prefix, account, calendar, "read-only")}
              label={dgettext("dashboard_calendar", "Read only")}
            />
            <CalendarColourPicker.toggle
              id={row_id(@id_prefix, account, calendar, "colour")}
              account={account}
              calendar={calendar}
              open={@colours.open == {account.id, calendar.id}}
              controls={row_id(@id_prefix, account, calendar, "colour-palette")}
              target={@target}
            />
            <CalendarColourPicker.palette
              :if={@colours.open == {account.id, calendar.id}}
              id={row_id(@id_prefix, account, calendar, "colour-palette")}
              account={account}
              calendar={calendar}
              selected={Map.get(@colours.keys, {account.id, calendar.id})}
              target={@target}
            />
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :checked, :boolean, required: true

  attr :disabled, :boolean,
    default: false,
    doc: "drawn `aria-disabled`, so it stays in the tab order to say why (`disabled_reason`)"

  attr :disabled_reason, :string, default: nil, doc: "why it cannot be ticked, in a tooltip"
  attr :reason_id, :string, default: nil, doc: "the reason's id, for `aria-describedby`"
  attr :colour, :string, required: true, doc: "a colour token from ColourTokens"
  attr :label, :string, required: true
  attr :described_by, :string, default: nil, doc: "ids of the markers that qualify the label"
  attr :event, :string, required: true
  attr :values, :map, required: true
  attr :data, :list, required: true
  attr :target, :any, required: true

  # A checkbox that cannot be ticked stays focusable and says why: it is
  # `aria-disabled` with no click, its reason in a tooltip it is described
  # by. The server refuses the toggle as well (`Visibility.toggle_calendar/3`).
  defp check(assigns) do
    ~H"""
    <.tooltip
      :let={tip}
      id={@disabled && @reason_id}
      text={@disabled && @disabled_reason}
    >
      <button
        type="button"
        role="checkbox"
        aria-checked={to_string(@checked)}
        aria-label={@label}
        aria-describedby={describe([@described_by, tip])}
        aria-disabled={@disabled && "true"}
        phx-click={!@disabled && @event}
        phx-target={@target}
        class="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-token-sm aria-disabled:cursor-not-allowed focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
        {value_attrs(@values)}
        {@data}
      >
        <span
          class={["cal-check", @checked && "is-checked"]}
          style={"--cal-ev: var(--color-#{@colour})"}
        >
          <.icon :if={@checked} name="hero-check-micro" class="h-3 w-3" />
        </span>
      </button>
    </.tooltip>
    """
  end

  defp describe(ids) do
    case Enum.filter(ids, &is_binary/1) do
      [] -> nil
      present -> Enum.join(present, " ")
    end
  end

  attr :label, :string, required: true
  attr :id, :string, default: nil, doc: "names the words for a checkbox's `aria-describedby`"

  defp lock(assigns) do
    ~H"""
    <.tooltip text={@label}>
      <span data-read-only class="shrink-0 text-tymeslot-400">
        <.icon name="hero-lock-closed-mini" class="h-4 w-4" />
        <span id={@id} class="sr-only">{@label}</span>
      </span>
    </.tooltip>
    """
  end

  attr :id, :string, required: true
  attr :spell_out, :boolean, required: true

  defp not_blocking(assigns) do
    ~H"""
    <span
      :if={@spell_out}
      id={@id}
      data-not-blocking
      class="shrink-0 rounded-token-sm bg-tymeslot-100 px-1.5 py-0.5 text-token-xs font-semibold text-tymeslot-500"
    >
      {dgettext("dashboard_calendar", "Doesn't block")}
    </span>
    <.tooltip :if={!@spell_out} text={dgettext("dashboard_calendar", "Doesn't block")}>
      <span data-not-blocking class="shrink-0 text-tymeslot-400">
        <.icon name="hero-eye-mini" class="h-4 w-4" />
        <span id={@id} class="sr-only">{dgettext("dashboard_calendar", "Doesn't block")}</span>
      </span>
    </.tooltip>
    """
  end

  # The ids of the words that qualify a calendar's checkbox, or nil.
  defp described_by(prefix, account, calendar) do
    ids =
      [
        {not calendar.blocks, "not-blocking"},
        {calendar.read_only and not account.read_only, "read-only"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map_join(" ", fn {_applies, part} -> row_id(prefix, account, calendar, part) end)

    if ids == "", do: nil, else: ids
  end

  defp row_id(prefix, account, calendar, part) do
    safe = String.replace(calendar.id, ~r/[^\w-]/u, "-")
    item_id(prefix, "calendar-#{account.id}-#{safe}-#{part}")
  end

  defp value_attrs(values),
    do: Enum.map(values, fn {key, value} -> {"phx-value-#{key}", value} end)

  # The rail keeps the ids it has always had; any other copy prefixes its own.
  defp item_id("calendar-rail", name), do: "calendar-#{name}"
  defp item_id(prefix, name), do: "#{prefix}-#{name}"

  defp connect_link_id("calendar-rail"), do: "calendar-connect"
  defp connect_link_id(prefix), do: "#{prefix}-connect-link"
end
