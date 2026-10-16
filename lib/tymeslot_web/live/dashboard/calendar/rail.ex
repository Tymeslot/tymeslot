defmodule TymeslotWeb.Dashboard.Calendar.Rail do
  @moduledoc """
  The collapsible left rail of the calendar surface: a mini-month of the
  visible range, then the organiser's calendars grouped by account, each with
  a colour checkbox and a lock when Tymeslot cannot write to it.

  Calendar sets and the bookable layer join the rail in later plans. On
  phones the rail is hidden and the toolbar's filter chip says what is
  hidden instead.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Calendar.MiniMonth

  attr :accounts, :list, required: true
  attr :mini_cursor, :any, required: true
  attr :view, :atom, required: true
  attr :days, :list, required: true
  attr :today, :any, required: true
  attr :week_start, :atom, required: true
  attr :locale, :string, required: true
  attr :target, :any, required: true

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
        days={@days}
        today={@today}
        week_start={@week_start}
        locale={@locale}
        target={@target}
      />
      <section aria-labelledby="calendar-rail-heading">
        <h2
          id="calendar-rail-heading"
          class="mb-2 text-token-xs font-semibold uppercase tracking-wide text-tymeslot-500"
        >
          {dgettext("dashboard_calendar", "Calendars")}
        </h2>
        <p :if={@accounts == []} class="text-token-sm text-tymeslot-500">
          {dgettext("dashboard_calendar", "No calendars connected yet.")}
        </p>
        <div :for={account <- @accounts} id={"calendar-account-#{account.id}"} class="mb-3 last:mb-0">
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
              id={"calendar-account-#{account.id}-name"}
              class="min-w-0 flex-1 truncate text-token-sm font-semibold text-tymeslot-800"
            >
              {account.name}
            </span>
            <.lock :if={account.read_only} label={dgettext("dashboard_calendar", "Read only")} />
          </div>
          <ul
            role="group"
            aria-labelledby={"calendar-account-#{account.id}-name"}
            class={["ml-6 space-y-0.5", account.hidden && "opacity-60"]}
          >
            <li :for={calendar <- account.calendars} class="flex items-center gap-2 py-0.5">
              <.check
                checked={not calendar.hidden}
                disabled={account.hidden}
                colour={calendar.colour}
                label={calendar.name}
                event="calendar:toggle_calendar"
                values={%{"integration-id" => account.id, "calendar-id" => calendar.id}}
                data={[{"data-calendar-id", calendar.id}]}
                target={@target}
              />
              <span class="min-w-0 flex-1 truncate text-token-sm text-tymeslot-700">{calendar.name}</span>
              <.lock
                :if={calendar.read_only and not account.read_only}
                label={dgettext("dashboard_calendar", "Read only")}
              />
            </li>
          </ul>
        </div>
      </section>
    </aside>
    """
  end

  attr :checked, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :colour, :string, required: true, doc: "a colour token from ColourTokens"
  attr :label, :string, required: true
  attr :event, :string, required: true
  attr :values, :map, required: true
  attr :data, :list, required: true
  attr :target, :any, required: true

  defp check(assigns) do
    ~H"""
    <button
      type="button"
      role="checkbox"
      aria-checked={to_string(@checked)}
      aria-label={@label}
      aria-disabled={@disabled && "true"}
      disabled={@disabled}
      phx-click={!@disabled && @event}
      phx-target={@target}
      class="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-token-sm disabled:cursor-not-allowed focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
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
    """
  end

  attr :label, :string, required: true

  defp lock(assigns) do
    ~H"""
    <span class="shrink-0 text-tymeslot-400" title={@label}>
      <.icon name="hero-lock-closed-mini" class="h-4 w-4" />
      <span class="sr-only">{@label}</span>
    </span>
    """
  end

  defp value_attrs(values),
    do: Enum.map(values, fn {key, value} -> {"phx-value-#{key}", value} end)
end
