defmodule TymeslotWeb.Dashboard.SyncLinksSettingsComponent do
  @moduledoc """
  The Integrations Hub tab where an organiser configures cross-calendar
  mirroring: which connected calendar's events get an opaque placeholder
  written onto which other calendar, so a tool booking against that second
  calendar sees the time as taken.

  ## Why the target calendar picker disappears

  Google and Outlook honour a `:calendar_id` in the event payload; the CalDAV
  family ignores it entirely and always writes to the primary calendar path.
  Offering the picker for a CalDAV target would let the organiser record a
  choice the engine cannot act on, and then show it back to them as though
  mirrors were landing there.

  The question is asked of `SyncLink.Capability`, which holds that asymmetry in
  one table alongside the three others and answers for a provider *string* as
  readily as an atom. That last part is the load-bearing half:
  `ProviderConfig.caldav_based?/1` is atom-only, so handed the `"nextcloud"`
  string that comes off the integration row and off the form parameter it falls
  through to its catch-all and answers `false`. A picker gated on it would stay
  visible for exactly the providers it exists to hide from, and nothing would
  fail loudly — the changeset would quietly null the field out and the form
  would keep showing a calendar the organiser had picked.

  Subscriptions are excluded from the target list at source rather than
  rejected on submit. `Ics.Provider.create_event/2` answers
  `{:error, :read_only}`, so such a link could never mirror anything; the
  changeset refuses it too, but offering it and then refusing it teaches the
  organiser nothing they could not have been told up front.

  Writes go through `Tymeslot.Integrations.Calendar.SyncLink`, never through a
  query module: the query modules are not user-scoped and a link names two
  forgeable integration ids. See that module's moduledoc.

  ## Why the conflict log is on this page at all

  Mirroring resolves divergences without asking: a placeholder edited on the
  target is overwritten, and a source deleted while its placeholder was edited
  takes the placeholder with it. Both are the right answers and both destroy
  work, so an organiser who does not see them recorded has no way to tell a
  resolution from a bug — the placeholder simply reverts, or vanishes, and the
  only remaining hypothesis is that mirroring is broken.

  The history is rendered inline under each link rather than behind a click, for
  the same reason the links themselves are: the panel is where mirroring is
  reasoned about, and a log nobody opens is a log nobody reads.
  `ConflictHistory.recent_for_user/2` answers for every link at once and is
  scoped by owner in SQL, so the listing costs one query however many links
  there are.

  The refresh button re-reads *one* link by an id that arrives from the browser,
  so it goes through `ConflictHistory.for_link/3`, which checks ownership. A
  forged id answers `{:error, :not_found}` and the panel is left exactly as it
  was.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias Tymeslot.Integrations.Calendar.SyncLink.ConflictHistory
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkMatrix
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkSettingsPanel
  alias TymeslotWeb.Dashboard.SyncLinks.ConflictLabels

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:links, [])
     |> assign(:conflicts, %{})
     |> assign(:form_values, %{})
     |> assign(:form_error, nil)
     |> assign(:matrix_error, nil)
     |> assign(:selected_link_id, nil)
     |> assign(:settings_values, %{})
     |> assign(:settings_error, nil)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:links, SyncLink.list_links(user_id))
     |> assign(:conflicts, ConflictHistory.recent_for_user(user_id))
     |> assign_new(:form_values, fn -> %{} end)
     |> assign_new(:form_error, fn -> nil end)
     |> assign_new(:matrix_error, fn -> nil end)
     |> assign_new(:selected_link_id, fn -> nil end)
     |> assign_new(:settings_values, fn -> %{} end)
     |> assign_new(:settings_error, fn -> nil end)}
  end

  # Selecting a cell is a read: it opens the settings for a link the organiser
  # can already see. The id arrives off the wire, so the link is looked up in
  # the assigns rather than trusted — a forged id finds nothing and the panel
  # stays as it was, which also declines to tell a prober whether the id
  # existed.
  @impl Phoenix.LiveComponent
  def handle_event("select_sync_cell", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.links, &(&1.id == cast_id(id))) do
      nil ->
        {:noreply, socket}

      link ->
        {:noreply,
         socket
         |> assign(:selected_link_id, link.id)
         |> assign(:settings_values, %{})
         |> assign(:settings_error, nil)}
    end
  end

  def handle_event("deselect_sync_cell", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  # The tier drives whether a label field is asked for, so the form round-trips
  # through here to keep that decision on the latest choice rather than on what
  # was stored when the panel opened.
  def handle_event("validate_sync_link_settings", %{"sync_link" => params}, socket) do
    {:noreply, assign(socket, :settings_values, params)}
  end

  def handle_event("save_sync_link_settings", %{"sync_link" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case {socket.assigns.selected_link_id, RateLimiter.check_sync_link_write_rate_limit(user_id)} do
      {nil, _limit} ->
        {:noreply, socket}

      {link_id, :ok} ->
        save_settings(socket, user_id, link_id, params)

      {_link_id, {:error, :rate_limited, message}} ->
        {:noreply, assign(socket, :settings_error, message)}

      {_link_id, {:error, :invalid_user_id}} ->
        {:noreply, assign(socket, :settings_error, generic_error())}
    end
  end

  # The grid saves whole. One rate-limit charge covers the submit rather than
  # one per cell: a five-calendar grid is twenty cells against a bucket of
  # sixty, so metering per cell would let three deliberate saves exhaust a
  # budget the limiter's own docs describe as covering "rebuilding an entire
  # set of links in one sitting" — and being refused halfway would leave the
  # grid disagreeing with what is stored.
  def handle_event("save_sync_link_matrix", params, socket) do
    user_id = socket.assigns.current_user.id

    cells =
      SyncLinkMatrix.parse_submission(
        Map.get(params, "matrix", %{}),
        socket.assigns.integrations
      )

    case RateLimiter.check_sync_link_write_rate_limit(user_id) do
      :ok -> apply_matrix(socket, user_id, cells)
      {:error, :rate_limited, message} -> {:noreply, assign(socket, :matrix_error, message)}
      {:error, :invalid_user_id} -> {:noreply, assign(socket, :matrix_error, generic_error())}
    end
  end

  def handle_event("toggle_sync_link", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    enabled? = not currently_enabled?(socket.assigns.links, id)

    with :ok <- RateLimiter.check_sync_link_write_rate_limit(user_id),
         {:ok, _link} <- SyncLink.toggle_enabled(user_id, cast_id(id), enabled?) do
      {:noreply, refresh(socket, user_id)}
    else
      _refused -> {:noreply, refresh(socket, user_id)}
    end
  end

  # A read, not a write, so no rate-limit bucket: it costs one indexed query
  # against rows the organiser already has rendered. The id comes off the wire,
  # so `ConflictHistory.for_link/3` checks the ownership the query module cannot.
  def handle_event("show_sync_link_conflicts", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case ConflictHistory.for_link(user_id, cast_id(id)) do
      {:ok, conflicts} ->
        {:noreply,
         assign(socket, :conflicts, Map.put(socket.assigns.conflicts, cast_id(id), conflicts))}

      # Someone else's link, or none at all. The panel is left as it stands
      # rather than cleared, which would tell a prober that the id was real
      # enough to have had an effect.
      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_sync_link", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with :ok <- RateLimiter.check_sync_link_write_rate_limit(user_id),
         {:ok, _link} <- SyncLink.delete_link(user_id, cast_id(id)) do
      {:noreply, refresh(socket, user_id)}
    else
      _refused -> {:noreply, refresh(socket, user_id)}
    end
  end

  # `update_link/3` re-verifies ownership of both ends against the acting user,
  # so a forged link id is refused there as well as at selection.
  defp save_settings(socket, user_id, link_id, params) do
    case SyncLink.update_link(user_id, link_id, params) do
      {:ok, _link} ->
        # The selection is kept rather than cleared: a save that closed the
        # panel would make a second change to the same link a fresh hunt for
        # its cell. Cleared *values* though, so the panel re-reads what was
        # actually stored rather than echoing the submission back.
        {:noreply,
         socket
         |> assign(:settings_values, %{})
         |> assign(:settings_error, nil)
         |> refresh(user_id)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:settings_values, params)
         |> assign(:settings_error, first_error(changeset))}

      {:error, :not_found} ->
        {:noreply, clear_selection(socket)}
    end
  end

  defp clear_selection(socket) do
    socket
    |> assign(:selected_link_id, nil)
    |> assign(:settings_values, %{})
    |> assign(:settings_error, nil)
  end

  defp apply_matrix(socket, user_id, cells) do
    case SyncLink.apply_matrix(user_id, cells) do
      {:ok, _summary} ->
        {:noreply,
         socket
         |> assign(:matrix_error, nil)
         |> refresh(user_id)}

      {:error, reason} ->
        # The grid is redrawn from what was actually stored rather than from
        # what was submitted: a partly-applied save is reported honestly, and
        # a redraw from the submitted state would show links that do not exist.
        {:noreply,
         socket
         |> assign(:matrix_error, matrix_error_message(reason))
         |> refresh(user_id)}
    end
  end

  # A changeset already worked out *why* — that the target is a read-only
  # subscription, say — and collapsing that into "could not be linked" throws
  # away the one sentence that tells the organiser whether to untick the cell
  # or try again. Anything without a message of its own still falls back:
  # `:not_found` means a forged id, and naming it would confirm to a prober
  # which ids exist.
  defp matrix_error_message(%Ecto.Changeset{} = changeset), do: first_error(changeset)
  defp matrix_error_message(_reason), do: generic_error()

  # Sibling components render the same integrations from their own assigns and
  # have no PubSub to learn a link changed, so the dashboard is told to refresh
  # them. `dashboard_live.ex` catches this and re-renders the hub.
  defp refresh(socket, user_id) do
    send(self(), {:integration_updated, :calendar})

    socket
    |> assign(:links, SyncLink.list_links(user_id))
    |> assign(:conflicts, ConflictHistory.recent_for_user(user_id))
  end

  defp currently_enabled?(links, id) do
    parsed = cast_id(id)

    case Enum.find(links, &(&1.id == parsed)) do
      nil -> false
      link -> link.enabled
    end
  end

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _not_an_id -> nil
    end
  end

  defp cast_id(id) when is_integer(id), do: id
  defp cast_id(_other), do: nil

  # The changeset's first message, already the field-specific one the schema
  # writes ("is a read-only subscription and cannot receive mirrored events").
  #
  # Through `translate_error/1` rather than assigned raw, because what the
  # changeset carries is a msgid, not a sentence: the schema stores it with
  # `dgettext_noop/2` precisely so the lookup happens here, at render, in the
  # reader's locale. Assigning it straight through put an English string inside
  # an otherwise translated panel — and did it for the *stock* Ecto validators
  # too, whose "can't be blank" has been translated in six locales all along.
  # The whole tuple is passed on, not just the message: `%{count}` and the rest
  # of a validator's interpolation live in the opts.
  # Named, because these are Ecto *field-suffix* messages: "has already been
  # linked" is a predicate with its subject stripped off, and a banner is the
  # one place it appears without the field label that completes it. Rendered
  # bare it reads as a fragment in every locale — the German and French are
  # worse, since neither puts the verb where English does. Prefixing the field's
  # own name restores the sentence the message was written to finish.
  defp first_error(%Ecto.Changeset{errors: [{field, error} | _rest]}),
    do: "#{field_label(field)} #{Forms.translate_error(error)}"

  defp first_error(_changeset), do: generic_error()

  defp field_label(:source_integration_id),
    do: dgettext("dashboard_integrations", "The source calendar")

  defp field_label(:target_integration_id),
    do: dgettext("dashboard_integrations", "The target calendar")

  defp field_label(:generic_label), do: dgettext("dashboard_integrations", "The label")

  defp field_label(:mirror_colour), do: dgettext("dashboard_integrations", "The colour")

  defp field_label(:target_calendar_id),
    do: dgettext("dashboard_integrations", "The chosen calendar")

  # A field this panel does not name is still worth reporting: the message half
  # is the part that says what went wrong, and a neutral subject beats silence.
  defp field_label(_field), do: dgettext("dashboard_integrations", "This link")

  defp generic_error,
    do: dgettext("dashboard_integrations", "That calendar could not be linked.")

  # ── Selection helpers ─────────────────────────────────────────────

  # Any active calendar may be a source: reading a feed is the one thing every
  # provider, subscriptions included, can do.
  # Labelled rather than named: two accounts of one provider store the same
  # name, so `integration.name` alone offers the organiser two identical
  # options to choose a direction between.
  defp source_options(integrations) do
    for integration <- integrations,
        integration.is_active,
        do: {DisplayHelpers.integration_label(integration), integration.id}
  end

  # No target selected yet is not "this target cannot choose a calendar" — it is
  # no target at all, and the note explaining the restriction would be claiming
  # something about a provider the organiser has not named. So `nil` gets its
  # own clause rather than falling through to `Capability`, whose honest answer
  # for a missing provider is `false`.
  defp target_without_calendar_choice?(nil), do: false

  # `:mirror_target` is asked first for the same reason the changeset asks it
  # first: a provider that cannot receive a mirror at all answers `false` to
  # `:target_calendar_choice` too, and explaining to the organiser that such a
  # target "always writes to its primary calendar" would describe writes it can
  # never perform. `target_options/1` keeps subscriptions out of the picker, so
  # this only bites on a forged form parameter — which is exactly when a
  # confident wrong sentence is worst.
  defp target_without_calendar_choice?(%{provider: provider}) do
    Capability.supports?(provider, :mirror_target) and
      not Capability.supports?(provider, :target_calendar_choice)
  end

  # Only calendars the organiser has selected for syncing, and only writable
  # ones — a mirror has to be created on the target, so a read-only calendar
  # within a writable account is no more usable than a read-only account.
  defp target_calendar_options(nil), do: []

  defp target_calendar_options(integration) do
    integration.calendar_list
    |> List.wrap()
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Enum.filter(&(&1.selected and not &1.read_only and is_binary(&1.id)))
    |> Enum.map(&{DisplayHelpers.extract_calendar_display_name(&1), &1.id})
  end

  # ── The link grid ─────────────────────────────────────────────────

  # Every active calendar is a row. Sources are unrestricted — reading a feed
  # is the one thing every provider can do — so the rows need no filtering and
  # the asymmetry lives entirely in the columns.
  defp privacy_tier_options do
    [
      {dgettext("dashboard_integrations", "Busy only"), "busy_only"},
      {dgettext("dashboard_integrations", "Generic label"), "generic_label"},
      {dgettext("dashboard_integrations", "Full details"), "full_passthrough"}
    ]
  end

  defp selected_link(_links, nil), do: nil
  defp selected_link(links, link_id), do: Enum.find(links, &(&1.id == link_id))

  @impl Phoenix.LiveComponent
  def render(assigns) do
    selected = selected_link(assigns.links, assigns.selected_link_id)

    # The picker's options come from the *link's* target, not from a form
    # field: the pair is already decided by the cell that was clicked.
    selected_target =
      selected && Enum.find(assigns.integrations, &(&1.id == selected.target_integration_id))

    assigns =
      assigns
      |> assign(:source_options, source_options(assigns.integrations))
      |> assign(:selected_link, selected)
      |> assign(
        :selected_without_calendar_choice?,
        target_without_calendar_choice?(selected_target)
      )
      |> assign(:selected_calendar_options, target_calendar_options(selected_target))
      |> assign(:privacy_tier_options, privacy_tier_options())

    ~H"""
    <div class="space-y-8">
      <.section_header
        icon="hero-arrow-path-rounded-square"
        title={dgettext("dashboard_integrations", "Calendar sync")}
      />

      <p class="max-w-2xl text-token-sm text-tymeslot-600">
        {dgettext(
          "dashboard_integrations",
          "Mirror one calendar's events onto another as busy placeholders, so tools booking against the second calendar see the time as taken."
        )}
      </p>

      <.info_box :if={@form_error} variant={:error}>{@form_error}</.info_box>

      <%!-- Two calendars are the minimum a link can name, so the form is
            pointless before then and the prompt says what to do instead. --%>
      <.info_box :if={length(@source_options) < 2} variant={:info}>
        {dgettext(
          "dashboard_integrations",
          "Connect a second calendar before setting up mirroring."
        )}
      </.info_box>

      <section :if={@links != []} class="space-y-3">
        <h2 class="text-token-lg font-bold text-tymeslot-900">
          {dgettext("dashboard_integrations", "Active links")}
        </h2>

        <ul class="space-y-3">
          <li
            :for={link <- @links}
            id={"sync-link-#{link.id}"}
            class="space-y-4 rounded-token-lg border border-tymeslot-200 bg-white p-4"
          >
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="min-w-0">
                <p class="text-token-sm font-semibold text-tymeslot-900">
                  {dgettext("dashboard_integrations", "%{source} to %{target}",
                    source: DisplayHelpers.integration_label(link.source_integration),
                    target: DisplayHelpers.integration_label(link.target_integration)
                  )}
                </p>
                <p class="text-token-xs text-tymeslot-500">
                  {privacy_tier_label(link)}
                  <span :if={not link.enabled} class="ml-2 font-semibold text-amber-600">
                    {dgettext("dashboard_integrations", "Paused")}
                  </span>
                </p>
              </div>

              <div class="flex items-center gap-2">
                <button
                  type="button"
                  phx-click="toggle_sync_link"
                  phx-value-id={link.id}
                  phx-target={@myself}
                  class="rounded-token-md border border-tymeslot-200 px-3 py-1.5 text-token-xs font-semibold text-tymeslot-700 hover:bg-tymeslot-50"
                >
                  {(link.enabled && dgettext("dashboard_integrations", "Pause")) ||
                    dgettext("dashboard_integrations", "Resume")}
                </button>
                <button
                  type="button"
                  phx-click="delete_sync_link"
                  phx-value-id={link.id}
                  phx-target={@myself}
                  class="rounded-token-md border border-red-200 px-3 py-1.5 text-token-xs font-semibold text-red-700 hover:bg-red-50"
                >
                  {dgettext("dashboard_integrations", "Remove")}
                </button>
              </div>
            </div>

            <%!-- Rendered only where there is a history. A link that has never
                  diverged has nothing to explain, and an empty box under every
                  link reads as a feature that failed to load. --%>
            <section
              :if={conflicts_for(@conflicts, link) != []}
              id={"sync-link-conflicts-#{link.id}"}
              class="space-y-2 border-t border-tymeslot-100 pt-3"
            >
              <div class="flex items-center justify-between gap-3">
                <h3 class="text-token-xs font-semibold uppercase tracking-wide text-tymeslot-500">
                  {dgettext("dashboard_integrations", "Recently resolved differences")}
                </h3>
                <button
                  type="button"
                  phx-click="show_sync_link_conflicts"
                  phx-value-id={link.id}
                  phx-target={@myself}
                  class="text-token-xs font-semibold text-tymeslot-600 hover:text-tymeslot-900"
                >
                  {dgettext("dashboard_integrations", "Refresh")}
                </button>
              </div>

              <ul class="space-y-2">
                <li
                  :for={conflict <- conflicts_for(@conflicts, link)}
                  class="text-token-xs text-tymeslot-600"
                >
                  <p class="font-semibold text-tymeslot-800">
                    {ConflictLabels.conflict_kind_label(conflict.kind)}
                  </p>
                  <p>{ConflictLabels.conflict_resolution_label(conflict.resolution)}</p>
                  <p class="break-all font-mono text-tymeslot-400">{conflict.source_uid}</p>
                </li>
              </ul>
            </section>
          </li>
        </ul>
      </section>

      <SyncLinkMatrix.sync_link_matrix
        integrations={@integrations}
        links={@links}
        error={@matrix_error}
        target={@myself}
        selected_link_id={@selected_link_id}
      />

      <SyncLinkSettingsPanel.sync_link_settings
        link={@selected_link}
        values={@settings_values}
        error={@settings_error}
        tier_options={@privacy_tier_options}
        calendar_options={@selected_calendar_options}
        without_calendar_choice?={@selected_without_calendar_choice?}
        target={@myself}
      />
    </div>
    """
  end

  defp conflicts_for(conflicts, link), do: Map.get(conflicts, link.id, [])

  # What the placeholder will actually say, not what tier was picked. The
  # generic-label row quotes the organiser's own words back at them, because
  # "Shown with a generic label" is a description of a setting rather than of
  # the block their colleagues will see — and while the label had no input to
  # arrive through, it was also false: every placeholder read "Busy".
  defp privacy_tier_label(%{privacy_tier: "generic_label", generic_label: label})
       when is_binary(label) and label != "" do
    dgettext("dashboard_integrations", "Shown as \"%{label}\"", label: label)
  end

  defp privacy_tier_label(%{privacy_tier: tier}), do: privacy_tier_label(tier)

  defp privacy_tier_label("busy_only"),
    do: dgettext("dashboard_integrations", "Shown as busy, with no detail")

  # A label-less row at that tier can only predate the input, and the honest
  # sentence is the one describing what the target calendar shows today.
  defp privacy_tier_label("generic_label"),
    do: dgettext("dashboard_integrations", "Shown as busy, until a placeholder title is set")

  defp privacy_tier_label("full_passthrough"),
    do: dgettext("dashboard_integrations", "Shown with the original title")

  defp privacy_tier_label(_tier), do: dgettext("dashboard_integrations", "Shown as busy")
end
