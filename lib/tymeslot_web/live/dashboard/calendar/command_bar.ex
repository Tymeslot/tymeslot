defmodule TymeslotWeb.Dashboard.Calendar.CommandBar do
  @moduledoc """
  The command bar (Ctrl K, Cmd K or `/`, or the search buttons): one input
  that searches events and bookings, goes to a typed date, runs a command
  or adds an event from a typed line.

  Always rendered, and hidden until `CommandMixin`
  (`assets/js/hooks/calendar_canvas/command.js`) runs `data-show`, a `JS`
  command that sets `data-open`; LiveView keeps that attribute through its
  patches, so the bar opens with no round trip and a patch never closes it.
  `data-hide` removes it and tells the server (`calendar:command_close`).
  The server renders the search rows (`CommandSearch`); the hook renders its
  own rows into the two ignored groups, `#calendar-command-instant` before
  them and `#calendar-command-after` after them, and owns the keyboard.
  Rows are not tab stops: the input keeps focus and names the active row in
  `aria-activedescendant`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :command, :map, required: true
  attr :target, :any, required: true

  @spec command_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def command_bar(assigns) do
    ~H"""
    <div
      id="calendar-command"
      class="cal-command"
      role="dialog"
      aria-modal="true"
      aria-labelledby="calendar-command-label"
      data-show={JS.set_attribute({"data-open", "true"}, to: "#calendar-command")}
      data-hide={
        "data-open"
        |> JS.remove_attribute(to: "#calendar-command")
        |> JS.push("calendar:command_close", target: @target)
      }
    >
      <div class="cal-command-scrim" data-command-scrim></div>
      <div class="cal-command-panel">
        <h2 id="calendar-command-label" class="sr-only">
          {dgettext("dashboard_calendar_power", "Search and commands")}
        </h2>
        <%!-- Never submitted by the browser: the hook takes Enter. phx-submit is the fallback. --%>
        <form
          novalidate
          id="calendar-command-form"
          class="cal-command-form"
          phx-change="calendar:command_query"
          phx-submit="calendar:command_query"
          phx-target={@target}
        >
          <.icon name="hero-magnifying-glass" class="h-5 w-5 shrink-0 text-tymeslot-500" />
          <%!-- raw-input: the command bar's combobox, drawn bare inside its own search row and driven by the canvas hook --%>
          <input
            id="calendar-command-input"
            name="q"
            type="text"
            value={@command.query}
            role="combobox"
            aria-expanded="false"
            aria-controls="calendar-command-list"
            aria-autocomplete="list"
            aria-labelledby="calendar-command-label"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="200"
            placeholder={dgettext("dashboard_calendar_power", "Search, or type a date or a command")}
          />
          <button
            type="button"
            class="cal-command-close"
            data-command-close
            aria-label={dgettext("dashboard_calendar", "Close")}
          >
            <.icon name="hero-x-mark-mini" class="h-5 w-5" />
          </button>
        </form>
        <div
          id="calendar-command-list"
          class="cal-command-list"
          role="listbox"
          aria-label={dgettext("dashboard_calendar_power", "Search and commands")}
        >
          <div
            id="calendar-command-instant"
            role="group"
            aria-label={dgettext("dashboard_calendar_power", "Suggestions")}
            phx-update="ignore"
          >
          </div>
          <div
            id="calendar-command-results"
            role="group"
            aria-label={dgettext("dashboard_calendar_power", "Search results")}
            aria-busy={to_string(@command.loading)}
          >
            <.result_group
              :if={@command.events != []}
              id="calendar-command-events"
              label={dgettext("dashboard_calendar_power", "Events")}
              rows={@command.events}
            />
            <.result_group
              :if={@command.bookings != []}
              id="calendar-command-bookings"
              label={dgettext("dashboard_calendar", "Bookings")}
              rows={@command.bookings}
            />
          </div>
          <div
            id="calendar-command-after"
            role="group"
            aria-label={dgettext("dashboard_calendar_power", "Suggestions")}
            phx-update="ignore"
          >
          </div>
        </div>
        <p id="calendar-command-status" class="sr-only" aria-live="polite">{status(@command)}</p>
        <p class="cal-command-hint" aria-hidden="true">
          {dgettext("dashboard_calendar_power", "Arrow keys move, Enter chooses, Esc closes.")}
        </p>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true

  defp result_group(assigns) do
    ~H"""
    <div id={@id} role="group" aria-labelledby={"#{@id}-label"}>
      <p id={"#{@id}-label"} role="presentation" class="cal-command-heading">{@label}</p>
      <button
        :for={row <- @rows}
        type="button"
        role="option"
        tabindex="-1"
        id={row.dom_id}
        class="cal-command-row"
        data-command-result
        data-reveal-ids={Enum.join(row.ids, ",")}
        data-date={Date.to_iso8601(row.date)}
        data-start-min={row.start_min}
        data-all-day={to_string(row.all_day)}
        style={"--cal-ev: var(--color-#{row.colour})"}
      >
        <span class="cal-command-swatch" aria-hidden="true"></span>
        <span class="cal-command-row-main">
          <span class="cal-command-row-title">{row.title}</span>
          <span class="cal-command-row-meta">
            {row.when_label}<span :if={row.detail}> · {row.detail}</span>
          </span>
        </span>
        <span :if={row.series} class="cal-command-badge">
          {dgettext("dashboard_calendar", "Repeats")}
        </span>
      </button>
    </div>
    """
  end

  defp status(%{error: true}),
    do: dgettext("dashboard_calendar_power", "Search failed. Try again.")

  defp status(%{loading: true}), do: dgettext("dashboard_calendar_power", "Searching…")

  defp status(%{query: query} = command) do
    if String.length(query) < 2, do: "", else: found(command)
  end

  defp found(%{events: [], bookings: []}), do: dgettext("dashboard_calendar_power", "No matches")

  defp found(%{events: events, bookings: bookings}) do
    dgettext("dashboard_calendar_power", "%{events}, %{bookings}",
      events:
        dngettext("dashboard_calendar", "%{count} event", "%{count} events", length(events)),
      bookings:
        dngettext(
          "dashboard_calendar_power",
          "%{count} booking",
          "%{count} bookings",
          length(bookings)
        )
    )
  end
end
