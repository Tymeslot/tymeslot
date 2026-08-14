defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkMatrix do
  @moduledoc """
  The link grid: every ordered pair of the organiser's calendars as one table
  of checkboxes, saved in a single submit.

  Extracted from `SyncLinksSettingsComponent` rather than written inline
  because the grid is the largest single piece of markup that panel renders and
  keeping it there pushed the module past the line budget the analyser
  enforces. The split is along a real seam: this module knows how to *draw* a
  matrix and nothing about how one is saved — the form's `phx-submit` targets
  the parent, which owns the rate limit, the parse and the write.

  ## The two ways a cell can be unavailable

  They are deliberately drawn differently, because they mean different things.

  A cell on the **diagonal** carries no control at all. A calendar mirroring
  onto itself is refused by the `calendar_sync_links_no_self_link` check
  constraint, so it is not an option that happens to be switched off — it is
  not an option. A disabled checkbox there would imply something the organiser
  might unlock.

  A cell in a **read-only column** renders as a disabled checkbox with a title
  explaining why. An ICS subscription can be a source but never a target
  (`Capability.supports?/2`, feature `:mirror_target`), and that asymmetry is
  worth showing rather than hiding: the organiser can see the calendar is
  known, is in the grid, and simply cannot receive.

  ## Why each checkbox carries a hidden partner

  An unchecked checkbox submits nothing at all, which the handler cannot tell
  apart from a cell that was never rendered. Without the paired hidden
  `"false"`, clearing a cell would be inexpressible and the grid could only
  ever add links. The hidden input is omitted for blocked cells, which have no
  state to submit.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability

  attr :integrations, :list, required: true
  attr :links, :list, required: true
  attr :error, :string, default: nil
  attr :target, :any, required: true
  attr :selected_link_id, :integer, default: nil

  @spec sync_link_matrix(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_matrix(assigns) do
    assigns =
      assigns
      |> assign(:calendars, grid_calendars(assigns.integrations))
      |> assign(:linked_pairs, linked_pairs(assigns.links))

    ~H"""
    <%!-- Two calendars is the smallest grid with a single off-diagonal cell.
          Below that it would render one row, one column and nothing to tick,
          which reads as broken rather than as empty. --%>
    <section :if={length(@calendars) >= 2} class="space-y-4">
      <div>
        <h2 class="text-token-lg font-bold text-tymeslot-900">
          {dgettext("dashboard_integrations", "Link grid")}
        </h2>
        <p class="text-token-sm text-tymeslot-600">
          {dgettext(
            "dashboard_integrations",
            "Tick a cell to mirror events from the calendar in that row onto the calendar in that column."
          )}
        </p>
      </div>

      <p :if={@error} class="text-token-sm font-semibold text-red-700">
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
        <div class="overflow-x-auto pb-2">
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
                <%!-- Column labels run vertically. A calendar named after an
                      account is far too long to sit horizontally over a 2rem
                      column, and truncating it produced headers reading
                      "Google Calendar — ta…", which is exactly the ambiguity
                      the label was introduced to remove. Rotated, the whole
                      name fits in a column no wider than its checkbox. --%>
                <th
                  :for={target <- @calendars}
                  scope="col"
                  class="h-40 w-9 p-1 align-bottom"
                >
                  <div class="flex h-full w-9 items-end justify-center">
                    <span
                      class="whitespace-nowrap text-token-xs font-semibold text-tymeslot-700"
                      style="writing-mode: vertical-rl; transform: rotate(180deg);"
                      title={DisplayHelpers.integration_label(target)}
                    >
                      {DisplayHelpers.integration_label(target)}
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
                  class="whitespace-nowrap py-1 pr-4 text-left text-token-xs font-semibold text-tymeslot-700"
                >
                  {DisplayHelpers.integration_label(source)}
                </th>
                <td
                  :for={target <- @calendars}
                  class={[
                    "w-9 p-1 text-center",
                    source.id == target.id && "bg-tymeslot-50"
                  ]}
                >
                  <%!-- The diagonal is drawn as a disabled checkbox rather than
                        left blank. A calendar cannot mirror onto itself — the
                        `calendar_sync_links_no_self_link` constraint refuses
                        it — but an empty cell removes the visual anchor that
                        makes a grid readable as a grid, and the eye loses which
                        row it is on. Disabled and shaded says "this is the
                        cell where a calendar meets itself" without offering
                        anything. --%>
                  <input
                    :if={source.id == target.id}
                    type="checkbox"
                    disabled
                    title={
                      dgettext(
                        "dashboard_integrations",
                        "A calendar cannot mirror onto itself."
                      )
                    }
                    class="h-4 w-4 cursor-not-allowed rounded-token-sm border-tymeslot-300 opacity-30"
                  />
                  <%!-- The hidden "false" is what makes clearing a cell
                        expressible: an unchecked box submits nothing at all,
                        which the handler cannot tell apart from a cell that was
                        never offered. --%>
                  <input
                    :if={source.id != target.id and not blocked?(target)}
                    type="hidden"
                    name={"matrix[#{cell_dom_id(source, target)}]"}
                    value="false"
                  />
                  <input
                    :if={source.id != target.id}
                    type="checkbox"
                    id={cell_dom_id(source, target)}
                    name={"matrix[#{cell_dom_id(source, target)}]"}
                    value="true"
                    checked={MapSet.member?(@linked_pairs, {source.id, target.id})}
                    disabled={blocked?(target)}
                    title={
                      blocked?(target) &&
                        dgettext(
                          "dashboard_integrations",
                          "This calendar is read-only and cannot receive mirrored events."
                        )
                    }
                    class="h-4 w-4 rounded-token-sm border-tymeslot-300 text-tymeslot-600 disabled:cursor-not-allowed disabled:opacity-40"
                  />
                  <%!-- Only a cell with a link behind it can be configured, so
                        the button exists only where one does. It sits under the
                        checkbox rather than replacing it: ticking is what
                        creates the link, this is what refines it. --%>
                  <button
                    :if={link_for(@links, source, target)}
                    type="button"
                    phx-click="select_sync_cell"
                    phx-value-id={link_id_for(@links, source, target)}
                    phx-target={@target}
                    title={dgettext("dashboard_integrations", "Configure this link")}
                    class={[
                      "mx-auto mt-1 block h-1.5 w-1.5 rounded-full",
                      (@selected_link_id == link_id_for(@links, source, target) &&
                         "bg-tymeslot-900") || "bg-tymeslot-300 hover:bg-tymeslot-600"
                    ]}
                  >
                    <span class="sr-only">
                      {dgettext("dashboard_integrations", "Configure this link")}
                    </span>
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-3">
          <p class="text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_integrations",
              "A greyed cell belongs to a read-only calendar, which can send but never receive. Click the dot under a ticked cell to configure that link."
            )}
          </p>
          <button
            type="submit"
            class="rounded-token-md bg-tymeslot-900 px-4 py-2 text-token-sm font-semibold text-white hover:bg-tymeslot-800"
          >
            {dgettext("dashboard_integrations", "Save grid")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  @doc """
  The DOM id and form key for one cell.
  """
  @spec cell_dom_id(map(), map()) :: String.t()
  def cell_dom_id(source, target), do: "sync-cell-#{source.id}-#{target.id}"

  @doc """
  Reads a submitted grid back into `{source_id, target_id}` pairs.

  Lives here rather than in the panel that handles the submit because it is the
  inverse of `cell_dom_id/2` above: the two encode and decode one format, and
  splitting them across modules is how they drift.

  Ticked cells are those whose value survived the browser overwriting the
  hidden partner. Only ids drawn from `calendars` are returned, so a cell
  naming a calendar the grid never offered is dropped here as well as being
  refused by the ownership check on the write path — the parser is a filter,
  not the authorisation.
  """
  @spec parse_submission(map(), [map()]) :: [{integer(), integer()}]
  def parse_submission(params, calendars) do
    offered = MapSet.new(calendars, & &1.id)

    params
    |> Enum.filter(fn {_cell_id, value} -> value in ["true", true, "on"] end)
    |> Enum.flat_map(fn {cell_id, _value} -> parse_cell_id(cell_id) end)
    |> Enum.filter(fn {source_id, target_id} ->
      source_id != target_id and MapSet.member?(offered, source_id) and
        MapSet.member?(offered, target_id)
    end)
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

  # Every active calendar is a row. Sources are unrestricted — reading a feed
  # is the one thing every provider can do — so the rows need no filtering and
  # the asymmetry lives entirely in the columns. Sorted by the label the grid
  # actually prints, so the headers read in the order the eye scans them.
  defp grid_calendars(integrations) do
    integrations
    |> Enum.filter(& &1.is_active)
    |> Enum.sort_by(&{String.downcase(DisplayHelpers.integration_label(&1)), &1.id})
  end

  # Keyed by the ordered pair so a cell is a set membership test rather than a
  # scan of every link per cell — a 5×5 grid asks this twenty times.
  defp linked_pairs(links) do
    MapSet.new(links, &{&1.source_integration_id, &1.target_integration_id})
  end

  # The link behind a cell, or `nil` where the pair is not linked. Scanned
  # rather than indexed because a grid is small — the list is one row per
  # configured link, not per possible pair.
  defp link_for(links, source, target) do
    Enum.find(links, fn link ->
      link.source_integration_id == source.id and link.target_integration_id == target.id
    end)
  end

  defp link_id_for(links, source, target) do
    case link_for(links, source, target) do
      nil -> nil
      link -> link.id
    end
  end

  defp blocked?(target), do: not Capability.supports?(target.provider, :mirror_target)
end
