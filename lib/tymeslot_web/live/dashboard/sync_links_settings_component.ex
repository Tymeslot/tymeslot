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

  The comparison is deliberately against `caldav_based_provider_strings/0` and
  not `caldav_based?/1`. That predicate is atom-only: handed the `"nextcloud"`
  string that comes off the integration row and off the form parameter, it
  falls through to its catch-all and answers `false`. A picker gated on it
  would stay visible for exactly the providers it exists to hide from, and
  nothing would fail loudly — the changeset would quietly null the field out
  and the form would keep showing a calendar the organiser had picked.

  Subscriptions are excluded from the target list at source rather than
  rejected on submit. `Ics.Provider.create_event/2` answers
  `{:error, :read_only}`, so such a link could never mirror anything; the
  changeset refuses it too, but offering it and then refusing it teaches the
  organiser nothing they could not have been told up front.

  Writes go through `Tymeslot.Integrations.Calendar.SyncLink`, never through a
  query module: the query modules are not user-scoped and a link names two
  forgeable integration ids. See that module's moduledoc.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Security.RateLimiter

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:links, [])
     |> assign(:form_values, %{})
     |> assign(:form_error, nil)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign(:links, SyncLink.list_links(socket.assigns.current_user.id))
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
    assign(socket, :links, SyncLink.list_links(user_id))
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
  defp first_error(%Ecto.Changeset{errors: [{_field, {message, _opts}} | _rest]}), do: message
  defp first_error(_changeset), do: generic_error()

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
        not ProviderConfig.subscription?(integration.provider),
        do: {integration.name, integration.id}
  end

  # `caldav_based?/1` is atom-only and would answer false for this string. The
  # string list is the only comparison that holds for a value off a DB row.
  defp caldav_target?(nil), do: false

  defp caldav_target?(%{provider: provider}),
    do: provider in ProviderConfig.caldav_based_provider_strings()

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
      |> assign(:caldav_target?, caldav_target?(target))
      |> assign(:target_calendar_options, target_calendar_options(target))
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
            class="flex flex-wrap items-center justify-between gap-4 rounded-token-lg border border-tymeslot-200 bg-white p-4"
          >
            <div class="min-w-0">
              <p class="text-token-sm font-semibold text-tymeslot-900">
                {dgettext("dashboard_integrations", "%{source} to %{target}",
                  source: link.source_integration.name,
                  target: link.target_integration.name
                )}
              </p>
              <p class="text-token-xs text-tymeslot-500">
                {privacy_tier_label(link.privacy_tier)}
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

          <%!-- Hidden for a CalDAV target: that family ignores a calendar id
                and always writes to the primary path. --%>
          <.input
            :if={not @caldav_target? and @target_calendar_options != []}
            type="select"
            name="sync_link[target_calendar_id]"
            id="sync-link-target-calendar"
            label={dgettext("dashboard_integrations", "Target calendar")}
            value={form_value(@form_values, "target_calendar_id")}
            options={@target_calendar_options}
            prompt={dgettext("dashboard_integrations", "Default calendar")}
          />

          <p :if={@caldav_target?} class="self-end text-token-xs text-tymeslot-500">
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

  defp privacy_tier_label("busy_only"),
    do: dgettext("dashboard_integrations", "Shown as busy, with no detail")

  defp privacy_tier_label("generic_label"),
    do: dgettext("dashboard_integrations", "Shown with a generic label")

  defp privacy_tier_label("full_passthrough"),
    do: dgettext("dashboard_integrations", "Shown with the original title")

  defp privacy_tier_label(_tier), do: dgettext("dashboard_integrations", "Shown as busy")
end
