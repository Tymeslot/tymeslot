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
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkCard
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkConflictSummary
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkMatrix
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkPairingPrompt
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkStaging

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:links, [])
     |> assign(:conflicts, %{})
     |> assign(:form_values, %{})
     |> assign(:form_error, nil)
     |> assign(:matrix_error, nil)
     |> assign(:staged_cells, %{})
     |> assign(:expanded_sources, MapSet.new())
     |> assign(:expanded_links, MapSet.new())
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
     |> assign_new(:staged_cells, fn -> %{} end)
     |> assign_new(:expanded_sources, fn -> MapSet.new() end)
     |> assign_new(:expanded_links, fn -> MapSet.new() end)
     |> assign_new(:settings_values, fn -> %{} end)
     |> assign_new(:settings_error, fn -> nil end)}
  end

  # Clicking a cell stages a change; nothing is written until the grid is
  # saved. The ids arrive off the wire and are staged unvalidated on purpose:
  # staging is a scratch pad, and both ends are checked against the acting
  # user by `apply_matrix/2` when the save actually happens. A forged pair
  # stages a cell that is not rendered and is refused on submit.
  #
  # The state the browser asks for is honoured rather than recomputed, so the
  # cell the organiser saw is the transition they get. An unrecognised value
  # leaves the grid alone rather than defaulting to a delete.
  @impl Phoenix.LiveComponent
  def handle_event("cycle_sync_cell", params, socket) do
    with {:ok, pair} <- SyncLinkStaging.cell_pair(params, &cast_id/1),
         {:ok, state} <- SyncLinkStaging.cast_state(params["state"]) do
      staged =
        SyncLinkStaging.stage(socket.assigns.staged_cells, socket.assigns.links, pair, state)

      {:noreply, assign(socket, :staged_cells, staged)}
    else
      _unusable -> {:noreply, socket}
    end
  end

  # Which accordion sections are open, on the mobile layout. A pure view
  # concern with nothing read and no id trusted: an unknown id expands a
  # section that is not rendered.
  def handle_event("toggle_sync_source", %{"id" => id}, socket) do
    case cast_id(id) do
      nil ->
        {:noreply, socket}

      source_id ->
        {:noreply,
         assign(socket, :expanded_sources, toggle(socket.assigns.expanded_sources, source_id))}
    end
  end

  def handle_event("discard_sync_link_matrix", _params, socket) do
    {:noreply,
     socket
     |> assign(:staged_cells, %{})
     |> assign(:matrix_error, nil)}
  end

  # Expansion is a pure view concern — no id is trusted and nothing is read —
  # so an unknown id simply expands a card that is not rendered.
  def handle_event("toggle_sync_link_card", %{"id" => id}, socket) do
    case cast_id(id) do
      nil ->
        {:noreply, socket}

      link_id ->
        {:noreply,
         assign(socket, :expanded_links, toggle(socket.assigns.expanded_links, link_id))}
    end
  end

  # The tier drives whether a label field is asked for, so the form round-trips
  # through here to keep that decision on the latest choice rather than on what
  # was stored when the card opened.
  #
  # Values are keyed by link because every card can be open at once: a single
  # in-flight map would show one card's unsaved tier inside all of them.
  def handle_event("validate_sync_link_settings", %{"sync_link" => params}, socket) do
    case cast_id(params["id"]) do
      nil ->
        {:noreply, socket}

      link_id ->
        {:noreply,
         assign(
           socket,
           :settings_values,
           Map.put(socket.assigns.settings_values, link_id, params)
         )}
    end
  end

  # The link id comes from the submitted form rather than from a selection,
  # because there is no selection any more. It is still forgeable, so
  # `update_link/3` re-verifies ownership of both ends — the id names which
  # card to write, never which row may be written.
  def handle_event("save_sync_link_settings", %{"sync_link" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case {cast_id(params["id"]), RateLimiter.check_sync_link_write_rate_limit(user_id)} do
      {nil, _limit} ->
        {:noreply, socket}

      {link_id, :ok} ->
        save_settings(socket, user_id, link_id, params)

      {link_id, {:error, :rate_limited, message}} ->
        {:noreply, assign(socket, :settings_error, {link_id, message})}

      {link_id, {:error, :invalid_user_id}} ->
        {:noreply, assign(socket, :settings_error, {link_id, generic_error()})}
    end
  end

  # The grid saves whole. One rate-limit charge covers the submit rather than
  # one per cell: a five-calendar grid is twenty cells against a bucket of
  # sixty, so metering per cell would let three deliberate saves exhaust a
  # budget the limiter's own docs describe as covering "rebuilding an entire
  # set of links in one sitting" — and being refused halfway would leave the
  # grid disagreeing with what is stored.
  #
  # The cells come from `staged_cells` rather than the submitted params: the
  # grid's controls are buttons, not inputs, so the form carries no cell state
  # at all. What is sent is the stored grid with the staged changes merged
  # over it — the full desired result, which is what `apply_matrix/2` diffs
  # against, and never a partial edit that would read as "delete everything
  # the organiser did not touch this sitting".
  def handle_event("save_sync_link_matrix", _params, socket) do
    user_id = socket.assigns.current_user.id
    cells = SyncLinkStaging.desired(socket.assigns.staged_cells, socket.assigns.links)

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

  # Dismissal is a write, so it is metered — but on the existing sync-link
  # bucket rather than one of its own. It is the same organiser writing to the
  # same page's data, and a second bucket would let a caller alternate between
  # the two to double the rate either one permits.
  #
  # The id goes to `ConflictHistory.dismiss/2`, which intersects it with the
  # links the acting user owns; a forged id clears nothing.
  def handle_event("dismiss_sync_link_conflicts", %{"id" => id}, socket) do
    {:noreply, dismiss_conflicts(socket, cast_id(id))}
  end

  def handle_event("dismiss_all_sync_link_conflicts", _params, socket) do
    {:noreply, dismiss_conflicts(socket, :all)}
  end

  def handle_event("delete_sync_link", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    link_id = cast_id(id)

    with :ok <- RateLimiter.check_sync_link_write_rate_limit(user_id),
         {:ok, _link} <- SyncLink.delete_link(user_id, link_id) do
      # The card is gone, so its expansion and its in-flight values go with it
      # — otherwise a later link reusing the id would open pre-expanded,
      # holding a removed link's unsaved edits.
      {:noreply,
       socket
       |> assign(:expanded_links, MapSet.delete(socket.assigns.expanded_links, link_id))
       |> drop_values(link_id)
       |> refresh(user_id)}
    else
      _refused -> {:noreply, refresh(socket, user_id)}
    end
  end

  # `update_link/3` re-verifies ownership of both ends against the acting user,
  # so a forged link id is refused there as well as at selection.
  defp save_settings(socket, user_id, link_id, params) do
    case SyncLink.update_link(user_id, link_id, params) do
      {:ok, _link} ->
        # The card stays open: a save that collapsed it would make a second
        # change to the same link a fresh hunt for its row. Its in-flight
        # values are dropped though, so the card re-reads what was actually
        # stored rather than echoing the submission back.
        {:noreply,
         socket
         |> drop_values(link_id)
         |> assign(:settings_error, nil)
         |> refresh(user_id)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> keep_values(link_id, params)
         |> assign(:settings_error, {link_id, first_error(changeset)})}

      # Someone else's link, or none at all. The card is collapsed and its
      # scratch values dropped; nothing is said about whether the id existed.
      {:error, :not_found} ->
        {:noreply,
         socket
         |> drop_values(link_id)
         |> assign(:expanded_links, MapSet.delete(socket.assigns.expanded_links, link_id))}

      # A re-point withdraws the placeholders from the old target first, so a
      # provider that refuses the delete surfaces its own reason here — neither
      # a changeset nor `:not_found`. Without this clause the save raised a
      # `CaseClauseError` and the organiser got "Connection Lost" for what is
      # an ordinary, recoverable refusal: the link kept its old target, the
      # mappings are in `pending_delete` for the reconcile sweep to finish, and
      # saving again once it has will work. The submission is kept so the panel
      # still holds what they typed.
      {:error, _provider_refused} ->
        {:noreply,
         socket
         |> keep_values(link_id, params)
         |> assign(:settings_error, {link_id, generic_error()})}
    end
  end

  defp dismiss_conflicts(socket, nil), do: socket

  defp dismiss_conflicts(socket, scope) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_sync_link_write_rate_limit(user_id) do
      :ok ->
        {:ok, _count} = ConflictHistory.dismiss(user_id, scope)
        refresh(socket, user_id)

      _refused ->
        socket
    end
  end

  # Set membership flipped: both accordions — sources on mobile, links in the
  # card list — are open/closed sets rather than a single selection, because
  # comparing two links means having both on screen.
  defp toggle(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp drop_values(socket, link_id),
    do: assign(socket, :settings_values, Map.delete(socket.assigns.settings_values, link_id))

  defp keep_values(socket, link_id, params),
    do: assign(socket, :settings_values, Map.put(socket.assigns.settings_values, link_id, params))

  defp apply_matrix(socket, user_id, cells) do
    case SyncLink.apply_matrix(user_id, cells) do
      {:ok, _summary} ->
        # Staging is cleared so the grid redraws from what was stored. Keeping
        # it would leave every saved cell still counted as pending, and the
        # organiser could not tell a saved grid from an unsaved one.
        {:noreply,
         socket
         |> assign(:staged_cells, %{})
         |> assign(:matrix_error, nil)
         |> refresh(user_id)}

      {:error, reason} ->
        # The grid is redrawn from what was actually stored rather than from
        # what was submitted: a partly-applied save is reported honestly, and
        # a redraw from the submitted state would show links that do not exist.
        # Staging is kept: the save failed, so the organiser's intent is still
        # unapplied, and clearing it would silently discard the edit they were
        # told did not happen.
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

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assigns
      |> assign(:source_options, source_options(assigns.integrations))
      |> assign(:privacy_tier_options, privacy_tier_options())
      |> assign(:total_conflicts, total_conflicts(assigns.conflicts, assigns.links))

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

      <SyncLinkPairingPrompt.sync_link_pairing_prompt
        source_count={length(@source_options)}
        integrations={@integrations}
      />

      <SyncLinkConflictSummary.sync_link_conflict_summary
        total={@total_conflicts}
        link_count={links_with_conflicts(@conflicts, @links)}
        target={@myself}
      />

      <SyncLinkMatrix.sync_link_matrix
        integrations={@integrations}
        links={@links}
        staged_cells={@staged_cells}
        expanded_sources={@expanded_sources}
        error={@matrix_error}
        target={@myself}
      />

      <section :if={@links != []} class="space-y-3">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h2 class="text-token-lg font-bold text-tymeslot-900">
            {dgettext("dashboard_integrations", "Links")}
          </h2>
          <span class="text-token-xs text-tymeslot-500">
            {dngettext(
              "dashboard_integrations",
              "%{count} link",
              "%{count} links",
              length(@links)
            )}
          </span>
        </div>

        <ul class="space-y-2">
          <SyncLinkCard.sync_link_card
            :for={link <- @links}
            link={link}
            conflicts={conflicts_for(@conflicts, link)}
            expanded?={MapSet.member?(@expanded_links, link.id)}
            values={Map.get(@settings_values, link.id, %{})}
            error={settings_error_for(@settings_error, link)}
            tier_options={@privacy_tier_options}
            calendar_options={calendar_options_for(@integrations, link)}
            without_calendar_choice?={without_calendar_choice_for?(@integrations, link)}
            target={@myself}
          />
        </ul>
      </section>
    </div>
    """
  end

  # The options come from the *link's* target, so a card always offers the
  # calendars of the calendar it actually writes to.
  defp target_for(integrations, link),
    do: Enum.find(integrations, &(&1.id == link.target_integration_id))

  defp calendar_options_for(integrations, link),
    do: integrations |> target_for(link) |> target_calendar_options()

  defp without_calendar_choice_for?(integrations, link),
    do: integrations |> target_for(link) |> target_without_calendar_choice?()

  # An error belongs to the card whose save produced it, not to every open
  # card: with several expanded at once, a shared error would report one link's
  # refusal under all of them.
  defp settings_error_for({link_id, message}, %{id: link_id}), do: message
  defp settings_error_for(_other, _link), do: nil

  defp conflicts_for(conflicts, link), do: Map.get(conflicts, link.id, [])

  # Counted over the links actually rendered rather than over every key in the
  # map, so a conflict belonging to a link that has since been removed cannot
  # inflate a total the organiser has no way to clear.
  defp total_conflicts(conflicts, links),
    do: links |> Enum.map(&length(conflicts_for(conflicts, &1))) |> Enum.sum()

  defp links_with_conflicts(conflicts, links),
    do: Enum.count(links, &(conflicts_for(conflicts, &1) != []))
end
