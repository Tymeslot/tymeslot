defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkMatrix do
  @moduledoc """
  The link grid: every ordered pair of the organiser's calendars as one table
  of cells, staged as they are clicked and written in a single submit.

  Extracted from `SyncLinksSettingsComponent` rather than written inline
  because the grid is the largest single piece of markup that panel renders and
  keeping it there pushed the module past the line budget the analyser
  enforces. The split is along a real seam: this module knows how to *draw* a
  matrix and nothing about how one is saved — the form's `phx-submit` targets
  the parent, which owns the rate limit, the parse and the write.

  ## The three states a cell carries

  A cell is a button that cycles, not a checkbox that ticks, because what it
  records has three values and a checkbox has two.

  `:active` mirrors. `:paused` keeps the link — its privacy tier, its label,
  its target calendar — and writes nothing until it is resumed. Absent means
  there is no link, and clearing a cell to absent is what deletes one.

  The middle state is the reason the grid stopped being a delete button. When a
  cell meant only "this link exists", clearing one withdrew every placeholder
  the link had written, permanently and from a single misclick — and a
  withdrawn placeholder is unrecoverable, because the busy blocks are
  deliberately indistinguishable from ordinary events, so the organiser could
  not see what had gone. The grid now cycles to `:paused` instead, and deletion
  moved to a deliberate action on the link's own card.

  ## Why the cells are buttons and the staging lives in the parent

  Clicking a cell edits `staged_cells` on the parent rather than writing
  anything, and the submit sends the whole staged map at once. Nothing reaches
  a calendar until the organiser presses save.

  That costs a round trip per click, which is affordable — a grid is clicked a
  handful of times in a sitting — and buys the property the write path needs:
  one rate-limit charge and one `apply_matrix/2` for a set of changes that were
  decided together. A grid that wrote per click would spend a five-calendar
  rebuild against a bucket sized for the whole sitting, and a refusal halfway
  would leave the rendered grid disagreeing with what is stored.

  The staged map is seeded from the stored links on every render where nothing
  is staged, so a cell always draws from one source: what is staged if the
  organiser has touched anything, what is stored otherwise.

  ## The two ways a cell can be unavailable

  They are deliberately drawn differently, because they mean different things.

  A cell on the **diagonal** carries no control at all. A calendar mirroring
  onto itself is refused by the `calendar_sync_links_no_self_link` check
  constraint, so it is not an option that happens to be switched off — it is
  not an option. A disabled control there would imply something the organiser
  might unlock.

  A cell in a **read-only column** renders as a disabled button with a title
  explaining why. An ICS subscription can be a source but never a target
  (`Capability.supports?/2`, feature `:mirror_target`), and that asymmetry is
  worth showing rather than hiding: the organiser can see the calendar is
  known, is in the grid, and simply cannot receive.

  ## Why the labels are stacked rather than rotated

  The column headers used to run vertically, because a label reading
  "Google Calendar — organiser@example.com" cannot sit horizontally over a
  column the width of a checkbox. Rotated text is unreadable at a glance and
  breaks every screen reader's reading order, and the width it saved is not
  needed once the label is split: `DisplayHelpers.integration_name/1` over
  `integration_qualifier/1` puts the name on one line and the account on the
  next, upright, in a column wide enough for both.

  The account is the half that matters here. Two Google calendars store the
  same literal name, so a header showing only the name offers the organiser two
  identical columns to choose a direction between.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkAccordion

  attr :integrations, :list, required: true
  attr :links, :list, required: true
  attr :staged_cells, :map, default: %{}
  attr :expanded_sources, :any, required: true
  attr :error, :string, default: nil
  attr :target, :any, required: true

  @spec sync_link_matrix(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_matrix(assigns) do
    calendars = grid_calendars(assigns.integrations)
    stored = stored_cells(assigns.links)
    staged = assigns.staged_cells

    assigns =
      assigns
      |> assign(:calendars, calendars)
      |> assign(:stored_cells, stored)
      |> assign(:effective_cells, Map.merge(stored, staged))
      |> assign(:changed_pairs, changed_pairs(stored, staged))

    ~H"""
    <%!-- Two calendars is the smallest grid with a single off-diagonal cell.
          Below that it would render one row, one column and nothing to click,
          which reads as broken rather than as empty. --%>
    <section :if={length(@calendars) >= 2} class="space-y-4">
      <%!-- Two headings, one per layout. The grid's names its axes, which is
            the only way to read a matrix; the accordion has no axes, so
            repeating "each row … each column" there would describe something
            not on screen. Each is hidden with the layout it belongs to. --%>
      <div>
        <h2 class="text-token-lg font-bold text-tymeslot-900">
          {dgettext("dashboard_integrations", "Links")}
        </h2>
        <p class="hidden text-token-sm text-tymeslot-600 sm:block">
          {dgettext(
            "dashboard_integrations",
            "The calendar in each row sends its events to the calendar in each column. Click a cell to mirror, click again to pause, and once more to remove the link."
          )}
        </p>
        <p class="text-token-sm text-tymeslot-600 sm:hidden">
          {dgettext(
            "dashboard_integrations",
            "Open a calendar to choose where its events are mirrored."
          )}
        </p>
      </div>

      <p :if={@error} class="text-token-sm font-semibold text-red-700" role="alert">
        {@error}
      </p>

      <.form
        for={%{}}
        id="sync-link-matrix-form"
        phx-submit="save_sync_link_matrix"
        phx-target={@target}
        class="space-y-4"
      >
        <%!-- `w-auto`, not `w-full`. A table told to fill the page spreads two
              columns across the whole viewport and the grid stops reading as a
              grid: the cells end up marooned, far from the labels that give
              them meaning. Sizing to content keeps rows and columns adjacent
              however few calendars there are. --%>
        <%!-- Below `sm:` the matrix becomes a list. A grid needs both axes on
              screen and a phone has room for one: at 375px the row header plus
              a single 132px column already fills the viewport, so the
              organiser scrolls sideways past one cell at a time while the
              header naming the row scrolls away with it. --%>
        <div class="sm:hidden">
          <SyncLinkAccordion.sync_link_accordion
            integrations={@integrations}
            links={@links}
            staged_cells={@staged_cells}
            expanded_sources={@expanded_sources}
            target={@target}
          />
        </div>

        <div class="hidden overflow-x-auto pb-2 sm:block">
          <table class="w-auto border-collapse text-token-sm">
            <thead>
              <tr>
                <%!-- The corner cell. `sr-only` text rather than an empty
                      header, so the table still announces what its axes mean. --%>
                <th class="p-1 text-left align-bottom">
                  <span class="sr-only">
                    {dgettext("dashboard_integrations", "Mirror from")}
                  </span>
                </th>
                <th
                  :for={target <- @calendars}
                  scope="col"
                  class="w-32 max-w-32 p-1 align-bottom"
                >
                  <div class="flex flex-col items-center gap-0.5 text-center">
                    <span class="max-w-full truncate text-token-xs font-semibold text-tymeslot-800">
                      {DisplayHelpers.integration_name(target)}
                    </span>
                    <span
                      :if={DisplayHelpers.integration_qualifier(target)}
                      class="max-w-full truncate font-mono text-token-2xs text-tymeslot-500"
                      title={DisplayHelpers.integration_qualifier(target)}
                    >
                      {DisplayHelpers.integration_qualifier(target)}
                    </span>
                  </div>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={source <- @calendars} class="border-t border-tymeslot-100">
                <%!-- Row labels stay horizontal and are not truncated: they sit
                      in the one column that can afford the width. --%>
                <th
                  scope="row"
                  class="whitespace-nowrap py-1 pr-4 text-left font-normal"
                >
                  <span class="block text-token-xs font-semibold text-tymeslot-800">
                    {DisplayHelpers.integration_name(source)}
                  </span>
                  <span
                    :if={DisplayHelpers.integration_qualifier(source)}
                    class="block font-mono text-token-2xs text-tymeslot-500"
                  >
                    {DisplayHelpers.integration_qualifier(source)}
                  </span>
                </th>
                <td
                  :for={target <- @calendars}
                  class={[
                    "w-32 p-1 text-center",
                    source.id == target.id && "bg-tymeslot-50"
                  ]}
                >
                  <%!-- The diagonal carries no control at all: a calendar
                        mirroring onto itself is refused by a check constraint,
                        so there is nothing to offer. The shaded cell and dash
                        keep the grid readable as a grid — without an anchor on
                        the diagonal the eye loses which row it is on. --%>
                  <span
                    :if={source.id == target.id}
                    class="select-none text-tymeslot-300"
                    title={
                      dgettext("dashboard_integrations", "A calendar cannot mirror onto itself.")
                    }
                    aria-label={
                      dgettext("dashboard_integrations", "A calendar cannot mirror onto itself.")
                    }
                  >
                    &mdash;
                  </span>
                  <.cell_button
                    :if={source.id != target.id}
                    source={source}
                    target={target}
                    state={Map.get(@effective_cells, {source.id, target.id})}
                    changed?={MapSet.member?(@changed_pairs, {source.id, target.id})}
                    target_component={@target}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Ordinary flow, not `position: sticky`.
              Sticky was tried and is wrong here: the dashboard scrolls an inner
              container rather than the document, so `bottom-0` resolves against
              this form — 449px tall around a 371px accordion — and the bar
              pinned *above* the sections it belongs under, painting over them.
              A bar that hides the controls it saves is worse than one the
              organiser has to scroll to.

              What made it seem necessary was the accordion's length, and that
              is bounded: one section per calendar, collapsed by default, so the
              footer is a short scroll away rather than a long one. --%>
        <div class="flex flex-wrap items-center justify-between gap-3 border-t border-tymeslot-100 pt-4">
          <%!-- Hidden with the grid it explains: the accordion labels its own
                segments in words, so the legend would be a key to a colour
                scheme that is not on screen. --%>
          <div class="hidden flex-wrap items-center gap-4 text-token-xs text-tymeslot-500 sm:flex">
            <span class="inline-flex items-center gap-1.5">
              <span class="h-3.5 w-5 rounded-token-sm border-2 border-turquoise-600 bg-turquoise-50" />
              {dgettext("dashboard_integrations", "Mirroring")}
            </span>
            <span class="inline-flex items-center gap-1.5">
              <span class="h-3.5 w-5 rounded-token-sm border-2 border-amber-300 bg-amber-50" />
              {dgettext("dashboard_integrations", "Paused")}
            </span>
            <span class="inline-flex items-center gap-1.5">
              <span class="h-3.5 w-5 rounded-token-sm border-2 border-tymeslot-200 bg-white" />
              {dgettext("dashboard_integrations", "Not linked")}
            </span>
            <span class="inline-flex items-center gap-1.5">
              <span class="h-3.5 w-5 rounded-token-sm border-2 border-dashed border-tymeslot-200 opacity-60" />
              {dgettext("dashboard_integrations", "Read-only, cannot receive")}
            </span>
          </div>

          <div class="flex items-center gap-3">
            <%!-- The count is the honest report of what a save will do. Without
                  it a staged grid is indistinguishable from a stored one, and
                  the organiser cannot tell whether they have already saved. --%>
            <span
              :if={MapSet.size(@changed_pairs) > 0}
              class="text-token-xs font-semibold text-turquoise-700"
            >
              {dngettext(
                "dashboard_integrations",
                "%{count} change staged",
                "%{count} changes staged",
                MapSet.size(@changed_pairs)
              )}
            </span>
            <button
              :if={MapSet.size(@changed_pairs) > 0}
              type="button"
              phx-click="discard_sync_link_matrix"
              phx-target={@target}
              class="rounded-token-md border border-tymeslot-200 bg-white px-3 py-1.5 text-token-xs font-semibold text-tymeslot-700 hover:bg-tymeslot-50"
            >
              {dgettext("dashboard_integrations", "Discard")}
            </button>
            <button
              type="submit"
              disabled={MapSet.size(@changed_pairs) == 0}
              class="rounded-token-md bg-tymeslot-900 px-4 py-2 text-token-sm font-semibold text-white hover:bg-tymeslot-800 disabled:cursor-default disabled:opacity-40"
            >
              {dgettext("dashboard_integrations", "Save grid")}
            </button>
          </div>
        </div>
      </.form>
    </section>
    """
  end

  # One cell. Blocked targets render the same button disabled rather than an
  # empty space, so the organiser can see the calendar is known and simply
  # cannot receive.
  attr :source, :map, required: true
  attr :target, :map, required: true
  attr :state, :atom, default: nil
  attr :changed?, :boolean, default: false
  attr :target_component, :any, required: true

  defp cell_button(assigns) do
    assigns =
      assigns
      |> assign(:blocked?, blocked?(assigns.target))
      |> assign(:next, next_state(assigns.state))

    ~H"""
    <button
      type="button"
      id={cell_dom_id(@source, @target)}
      phx-click={not @blocked? && "cycle_sync_cell"}
      phx-value-source={@source.id}
      phx-value-target={@target.id}
      phx-value-state={@next}
      phx-target={@target_component}
      disabled={@blocked?}
      aria-pressed={to_string(@state == :active)}
      title={cell_title(@blocked?, @state, @source, @target)}
      class={[
        "mx-auto flex h-9 w-16 items-center justify-center rounded-token-lg border-2 transition",
        cell_classes(@blocked?, @state),
        @changed? && "ring-2 ring-turquoise-400 ring-offset-1"
      ]}
    >
      <span class="text-token-sm leading-none" aria-hidden="true">&rarr;</span>
      <span class="sr-only">{cell_title(@blocked?, @state, @source, @target)}</span>
    </button>
    """
  end

  @doc """
  The DOM id for one cell.
  """
  @spec cell_dom_id(map(), map()) :: String.t()
  def cell_dom_id(source, target), do: "sync-cell-#{source.id}-#{target.id}"

  @doc """
  Reads a submitted grid back into a `{source_id, target_id} => state` map.

  Lives here rather than in the panel that handles the submit because it is the
  inverse of `cell_dom_id/2` above: the two encode and decode one format, and
  splitting them across modules is how they drift.

  A cell submits one of three values. `"active"` and `"paused"` are kept and
  become the map's values; anything else — including the `"off"` a cleared cell
  carries — is dropped, and a pair absent from the map is what tells
  `SyncLink.apply_matrix/2` to delete the link.

  Only ids drawn from `calendars` are returned, so a cell naming a calendar the
  grid never offered is dropped here as well as being refused by the ownership
  check on the write path — the parser is a filter, not the authorisation.
  """
  @spec parse_submission(map(), [map()]) :: %{{integer(), integer()} => :active | :paused}
  def parse_submission(params, calendars) do
    offered = MapSet.new(calendars, & &1.id)

    for {cell_id, value} <- params,
        state = cell_state(value),
        not is_nil(state),
        {source_id, target_id} <- parse_cell_id(cell_id),
        source_id != target_id,
        MapSet.member?(offered, source_id),
        MapSet.member?(offered, target_id),
        into: %{},
        do: {{source_id, target_id}, state}
  end

  @doc """
  The state a cell moves to when it is clicked.

  Public because the parent applies the same cycle when it stages a click, and
  a second copy of the order is how the button's title comes to describe a
  different transition from the one the click performs.

  The cycle ends at absent rather than looping back to `:active`, so removing a
  link is reachable from the grid — but it is the *last* stop, two clicks past
  the one that pauses, which is the whole point: an organiser who wants to stop
  mirroring finds pause first.
  """
  @spec next_state(atom()) :: :active | :paused | :off
  def next_state(nil), do: :active
  def next_state(:active), do: :paused
  def next_state(:paused), do: :off
  def next_state(:off), do: :active

  @doc """
  Casts a state that arrived off the wire.

  Anything unrecognised is `nil`, which the parent treats as no change rather
  than as a delete: a forged value should not be able to remove a link.
  """
  @spec cast_state(term()) :: :active | :paused | :off | nil
  def cast_state("active"), do: :active
  def cast_state("paused"), do: :paused
  def cast_state("off"), do: :off
  def cast_state(_unrecognised), do: nil

  @doc """
  The stored links as a `{source_id, target_id} => state` map.

  The grid's baseline: what a cell shows when nothing is staged, and what a
  staged change is compared against to decide whether it is a change at all.
  """
  @spec stored_cells([map()]) :: %{{integer(), integer()} => :active | :paused}
  def stored_cells(links) do
    Map.new(links, fn link ->
      {{link.source_integration_id, link.target_integration_id},
       (link.enabled && :active) || :paused}
    end)
  end

  @doc """
  The pairs a save would actually move.

  A staged value equal to what is stored is not a change, so it is neither
  counted nor ringed. Staging is edited rather than cleared as cells are
  clicked back and forth, so without this a cell clicked full circle would
  still claim to be pending.
  """
  @spec changed_pairs(map(), map()) :: MapSet.t()
  def changed_pairs(stored, staged) do
    for {pair, state} <- staged,
        Map.get(stored, pair) != normalise_state(state),
        into: MapSet.new(),
        do: pair
  end

  defp normalise_state(:off), do: nil
  defp normalise_state(state), do: state

  # A grid that submitted booleans could not say "keep this link but stop
  # mirroring", which is the state the whole redesign turns on.
  defp cell_state("active"), do: :active
  defp cell_state("paused"), do: :paused
  defp cell_state(_off_or_unknown), do: nil

  defp cell_classes(true, _state),
    do: "cursor-not-allowed border-dashed border-tymeslot-200 text-tymeslot-300 opacity-60"

  defp cell_classes(false, :active),
    do: "border-turquoise-600 bg-turquoise-50 text-turquoise-700 hover:border-turquoise-700"

  defp cell_classes(false, :paused),
    do: "border-amber-300 bg-amber-50 text-amber-700 hover:border-amber-500"

  defp cell_classes(false, _absent),
    do:
      "border-tymeslot-200 bg-white text-tymeslot-300 hover:border-turquoise-500 hover:bg-turquoise-50"

  # Named in full rather than "Mirroring" alone: the title is what a screen
  # reader announces for a cell, and a grid of twenty cells all announcing
  # "Mirroring" says nothing about which pair is being described.
  defp cell_title(true, _state, _source, target) do
    dgettext(
      "dashboard_integrations",
      "%{target} is read-only and cannot receive mirrored events.",
      target: DisplayHelpers.integration_label(target)
    )
  end

  defp cell_title(false, :active, source, target) do
    dgettext(
      "dashboard_integrations",
      "Mirroring %{source} onto %{target}. Click to pause.",
      source: DisplayHelpers.integration_label(source),
      target: DisplayHelpers.integration_label(target)
    )
  end

  defp cell_title(false, :paused, source, target) do
    dgettext(
      "dashboard_integrations",
      "Paused. Click to remove the link from %{source} to %{target}.",
      source: DisplayHelpers.integration_label(source),
      target: DisplayHelpers.integration_label(target)
    )
  end

  defp cell_title(false, _absent, source, target) do
    dgettext(
      "dashboard_integrations",
      "Mirror %{source} onto %{target}.",
      source: DisplayHelpers.integration_label(source),
      target: DisplayHelpers.integration_label(target)
    )
  end

  defp parse_cell_id("sync-cell-" <> rest) do
    case String.split(rest, "-") do
      [source, target] ->
        with {source_id, ""} <- Integer.parse(source),
             {target_id, ""} <- Integer.parse(target) do
          [{source_id, target_id}]
        else
          _unparseable -> []
        end

      _malformed ->
        []
    end
  end

  defp parse_cell_id(_other), do: []

  @doc """
  The calendars the grid offers, in the order it prints them.

  Every active calendar is a row. Sources are unrestricted — reading a feed is
  the one thing every provider can do — so the rows need no filtering and the
  asymmetry lives entirely in the columns. Sorted by the label actually
  rendered, so the headers read in the order the eye scans them.

  Public because the mobile accordion lists the same calendars in the same
  order. A second copy of "which calendars are offered" would let the two
  layouts disagree about what exists, which is the sort of difference nobody
  notices until an organiser rotates their phone.
  """
  @spec grid_calendars([map()]) :: [map()]
  def grid_calendars(integrations) do
    integrations
    |> Enum.filter(& &1.is_active)
    |> Enum.sort_by(&{String.downcase(DisplayHelpers.integration_label(&1)), &1.id})
  end

  @doc """
  Whether a calendar can receive a mirror at all.

  An ICS subscription can be a source but never a target — `create_event/2`
  answers `{:error, :read_only}` — so the cell naming it is drawn as refused
  rather than offered. Public for the same reason as `grid_calendars/1`: both
  layouts have to refuse the same pairs.
  """
  @spec blocked?(map()) :: boolean()
  def blocked?(target), do: not Capability.supports?(target.provider, :mirror_target)
end
