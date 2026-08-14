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

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:links, [])
     |> assign(:conflicts, %{})
     |> assign(:form_values, %{})
     |> assign(:form_error, nil)}
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
     |> assign_new(:form_error, fn -> nil end)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate_sync_link", %{"sync_link" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  def handle_event("create_sync_link", %{"sync_link" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_sync_link_write_rate_limit(user_id) do
      :ok -> create_link(socket, user_id, params)
      {:error, :rate_limited, message} -> {:noreply, assign(socket, :form_error, message)}
      {:error, :invalid_user_id} -> {:noreply, assign(socket, :form_error, generic_error())}
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

  defp create_link(socket, user_id, params) do
    case SyncLink.create_link(user_id, params) do
      {:ok, _link} ->
        {:noreply,
         socket
         |> assign(:form_values, %{})
         |> assign(:form_error, nil)
         |> refresh(user_id)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form_values, params)
         |> assign(:form_error, first_error(changeset))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:form_values, params)
         |> assign(:form_error, generic_error())}
    end
  end

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
  defp source_options(integrations) do
    for integration <- integrations, integration.is_active, do: {integration.name, integration.id}
  end

  # A subscription is excluded here rather than refused on submit; see the
  # moduledoc.
  defp target_options(integrations) do
    for integration <- integrations,
        integration.is_active,
        Capability.supports?(integration.provider, :mirror_target),
        do: {integration.name, integration.id}
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

  defp selected_target(integrations, form_values) do
    case Map.get(form_values, "target_integration_id") do
      nil -> nil
      "" -> nil
      id -> Enum.find(integrations, &(to_string(&1.id) == to_string(id)))
    end
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

  defp privacy_tier_options do
    [
      {dgettext("dashboard_integrations", "Busy only"), "busy_only"},
      {dgettext("dashboard_integrations", "Generic label"), "generic_label"},
      {dgettext("dashboard_integrations", "Full details"), "full_passthrough"}
    ]
  end

  defp form_value(form_values, key, default \\ ""), do: Map.get(form_values, key, default)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    target = selected_target(assigns.integrations, assigns.form_values)

    assigns =
      assigns
      |> assign(:source_options, source_options(assigns.integrations))
      |> assign(:target_options, target_options(assigns.integrations))
      |> assign(:selected_target, target)
      |> assign(:target_without_calendar_choice?, target_without_calendar_choice?(target))
      |> assign(:target_calendar_options, target_calendar_options(target))
      |> assign(:privacy_tier_options, privacy_tier_options())
      |> assign(
        :generic_label_tier?,
        form_value(assigns.form_values, "privacy_tier", "busy_only") == "generic_label"
      )

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
                    source: link.source_integration.name,
                    target: link.target_integration.name
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
                  <p class="font-semibold text-tymeslot-800">{conflict_kind_label(conflict.kind)}</p>
                  <p>{conflict_resolution_label(conflict.resolution)}</p>
                  <p class="break-all font-mono text-tymeslot-400">{conflict.source_uid}</p>
                </li>
              </ul>
            </section>
          </li>
        </ul>
      </section>

      <section :if={length(@source_options) >= 2} class="space-y-4">
        <h2 class="text-token-lg font-bold text-tymeslot-900">
          {dgettext("dashboard_integrations", "Add a link")}
        </h2>

        <.form
          for={%{}}
          id="sync-link-form"
          phx-submit="create_sync_link"
          phx-change="validate_sync_link"
          phx-target={@myself}
          class="grid gap-4 sm:grid-cols-2"
        >
          <.input
            type="select"
            name="sync_link[source_integration_id]"
            id="sync-link-source"
            label={dgettext("dashboard_integrations", "Mirror events from")}
            value={form_value(@form_values, "source_integration_id")}
            options={@source_options}
            prompt={dgettext("dashboard_integrations", "Choose a calendar")}
          />

          <.input
            type="select"
            name="sync_link[target_integration_id]"
            id="sync-link-target"
            label={dgettext("dashboard_integrations", "Onto")}
            value={form_value(@form_values, "target_integration_id")}
            options={@target_options}
            prompt={dgettext("dashboard_integrations", "Choose a calendar")}
          />

          <%!-- Hidden for a target without `:target_calendar_choice`: the
                CalDAV family ignores a calendar id and always writes to the
                primary path. --%>
          <.input
            :if={not @target_without_calendar_choice? and @target_calendar_options != []}
            type="select"
            name="sync_link[target_calendar_id]"
            id="sync-link-target-calendar"
            label={dgettext("dashboard_integrations", "Target calendar")}
            value={form_value(@form_values, "target_calendar_id")}
            options={@target_calendar_options}
            prompt={dgettext("dashboard_integrations", "Default calendar")}
          />

          <p :if={@target_without_calendar_choice?} class="self-end text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_integrations",
              "This provider always writes to its primary calendar."
            )}
          </p>

          <.input
            type="select"
            name="sync_link[privacy_tier]"
            id="sync-link-privacy-tier"
            label={dgettext("dashboard_integrations", "Show as")}
            value={form_value(@form_values, "privacy_tier", "busy_only")}
            options={@privacy_tier_options}
          />

          <%!-- Only the tier that uses it. Rendered for the other two, the
                field would ask for something neither writes: `busy_only` sends
                an opaque title and `full_passthrough` copies the source's own,
                and a label typed under either would be stored and never
                appear. --%>
          <.input
            :if={@generic_label_tier?}
            type="text"
            name="sync_link[generic_label]"
            id="sync-link-generic-label"
            label={dgettext("dashboard_integrations", "Placeholder title")}
            value={form_value(@form_values, "generic_label")}
            maxlength="255"
            placeholder={dgettext("dashboard_integrations", "Personal commitment")}
          />

          <div class="sm:col-span-2">
            <.action_button type="submit">
              {dgettext("dashboard_integrations", "Create link")}
            </.action_button>
          </div>
        </.form>
      </section>
    </div>
    """
  end

  defp conflicts_for(conflicts, link), do: Map.get(conflicts, link.id, [])

  # What happened, in the organiser's terms rather than the schema's. The stored
  # value is a code the engine writes; "mirror_edited" on a page means nothing to
  # someone who has never read the engine.
  defp conflict_kind_label("mirror_edited"),
    do:
      dgettext(
        "dashboard_integrations",
        "The busy block was edited on the target calendar."
      )

  defp conflict_kind_label("both_changed"),
    do:
      dgettext(
        "dashboard_integrations",
        "The original event and its busy block both changed."
      )

  defp conflict_kind_label("delete_race"),
    do:
      dgettext(
        "dashboard_integrations",
        "The original event was deleted while the placeholder was edited."
      )

  defp conflict_kind_label("write_failed"),
    do:
      dgettext(
        "dashboard_integrations",
        "The busy block could not be written to the target calendar."
      )

  # Both halves of the failure, because naming only one of them misleads. The
  # instinct is to call this over-blocking, and the freed slot is the visible
  # symptom — but the slot the occurrence moved *to* is unblocked and can be
  # booked over a meeting that is genuinely happening, which is the more
  # damaging half and the one nobody looks for unless told.
  defp conflict_kind_label("occurrence_moved"),
    do:
      dgettext(
        "dashboard_integrations",
        "One occurrence of this repeating event was moved. The busy block still sits at its original time, and no busy block covers its new time — so that slot can be double-booked."
      )

  # No longer produced — placeholders now carry the series' cancelled
  # occurrences — but historical rows are still rendered, because the table is
  # append-only and this was true of the placeholder at the time it was written.
  # The wording is past tense for that reason: an organiser reading a row from
  # last month must not go looking for a gap that today's placeholder does not
  # have.
  defp conflict_kind_label("series_exceptions"),
    do:
      dgettext(
        "dashboard_integrations",
        "The repeating busy block did not reflect cancelled occurrences at the time."
      )

  # A kind this version does not know how to name is still shown, because the
  # row's date and event are useful on their own and a silently dropped entry
  # would make the history lie about how many there were.
  defp conflict_kind_label(_kind),
    do: dgettext("dashboard_integrations", "The two calendars differed.")

  defp conflict_resolution_label("source_won"),
    do: dgettext("dashboard_integrations", "The original event was kept.")

  defp conflict_resolution_label("deletion_won"),
    do: dgettext("dashboard_integrations", "The busy block was removed.")

  defp conflict_resolution_label("skipped"),
    do: dgettext("dashboard_integrations", "Nothing was changed on the target calendar.")

  defp conflict_resolution_label(_resolution),
    do: dgettext("dashboard_integrations", "The difference was resolved automatically.")

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
