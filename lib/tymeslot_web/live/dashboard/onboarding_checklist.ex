defmodule TymeslotWeb.Dashboard.OnboardingChecklist do
  @moduledoc """
  Dashboard onboarding widget: a compact, dismissible checklist of what is
  worth doing after the setup wizard, each item linking straight to where it is
  done. The wizard already has the host connect a calendar, choose a theme, set
  up a meeting type and keep their link, so the checklist carries only what it
  leaves open:

    * connect a calendar: done while one can take bookings, so it reopens when
      the host disconnects it or its credentials are refused;
    * add a video provider: done once one is connected;
    * add your photo: done once the profile has an avatar;
    * introduce yourself: done once the profile has a headline or a bio, and
      offered only while the host's theme shows them on the booking page
      (`Tymeslot.Themes.Catalog.shows_intro?/1`);
    * add it to your website: done once a site may embed the booking page
      (`Tymeslot.Profiles.embedding_enabled?/1`).

  The provider items complete only from a real connection. The profile items can
  also be ticked off by hand, for a host who wants to skip one, and grey out
  immediately; once the profile itself has the thing, the item is done without a
  tick and offers none. The whole widget can also be closed. Both the per-item
  ticks and the global close persist on the user via `Tymeslot.Onboarding`; a
  tick stored for an item no longer in the catalogue is ignored.

  Gate rendering on `visible?/3`: the widget hides once every item is done or the
  host has closed it, so a fully set-up user never sees it and no empty container
  is left behind. Which items may be ticked by hand is a rule of
  `Tymeslot.Onboarding.manual_dashboard_setup_items/0`; the catalogue here only
  mirrors it, giving each manual item a checkbox and each provider item none.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Components.UI.CheckToggle

  @doc """
  Whether the widget should render for this host: not closed, and at least one
  setup item still outstanding.
  """
  @spec visible?(map(), map(), map() | nil) :: boolean()
  def visible?(current_user, integration_status, profile) do
    not Onboarding.dashboard_setup_dismissed?(current_user) and
      Enum.any?(items(integration_status, current_user, profile), &(not &1.done))
  end

  attr :integration_status, :map, required: true
  attr :current_user, :map, required: true
  attr :profile, :any, required: true

  attr :variant, :atom,
    default: :full,
    doc: "`:full` for the overview card, `:compact` for the collapsed strip above the calendar."

  @spec onboarding_checklist(map()) :: Phoenix.LiveView.Rendered.t()
  def onboarding_checklist(assigns) do
    items = items(assigns.integration_status, assigns.current_user, assigns.profile)

    assigns
    |> assign(
      items: items,
      done_count: Enum.count(items, & &1.done),
      total: length(items)
    )
    |> checklist_body()
  end

  # The calendar owns its whole viewport, so there the checklist is a single
  # collapsed row that opens on demand rather than a card that pushes the grid
  # below the fold. `<details>` keeps the open/closed state in the DOM, so
  # expanding it costs no LiveView round trip and survives grid re-renders.
  defp checklist_body(%{variant: :compact} = assigns) do
    assigns = assign(assigns, :next_item, Enum.find(assigns.items, &(not &1.done)))

    ~H"""
    <div
      class="flex items-center gap-2 rounded-token-xl border border-turquoise-200 bg-white px-3 py-2 shadow-sm"
      data-testid="onboarding-checklist"
      data-tour="quick-actions"
      phx-remove={JS.transition("onboarding-checklist--leaving", time: 500)}
    >
      <details class="group min-w-0 flex-1 [&>summary::-webkit-details-marker]:hidden">
        <%!-- Named by its content, so the accessible name carries the visible
              title and progress count that voice control users will say. --%>
        <summary class="flex cursor-pointer list-none items-center gap-2 text-token-sm">
          <.pill tone={:brand}>{@done_count}/{@total}</.pill>
          <span class="font-bold text-tymeslot-800">
            {dgettext("dashboard_home", "Finish setting up")}
          </span>
          <span :if={@next_item} class="hidden truncate text-tymeslot-500 sm:inline">
            · {@next_item.title}
          </span>
          <.icon
            name="hero-chevron-down"
            class="ml-auto h-4 w-4 shrink-0 text-tymeslot-400 transition-transform group-open:rotate-180"
          />
        </summary>

        <ul class="mt-3 space-y-2">
          <li :for={item <- @items}>
            <.item_row item={item} />
          </li>
        </ul>
      </details>

      <.icon_button
        icon="hero-x-mark"
        label={dgettext("dashboard_home", "Dismiss setup checklist")}
        size={:sm}
        phx-click="onboarding:dismiss"
      />
    </div>
    """
  end

  defp checklist_body(assigns) do
    ~H"""
    <.card
      tag="section"
      class="onboarding-checklist"
      data-testid="onboarding-checklist"
      data-tour="quick-actions"
      aria-labelledby="onboarding-checklist-title"
      phx-remove={JS.transition("onboarding-checklist--leaving", time: 500)}
      title={dgettext("dashboard_home", "Finish setting up")}
      title_id="onboarding-checklist-title"
      description={
        dgettext(
          "dashboard_home",
          "A few recommended steps. Tick off the ones you don't need."
        )
      }
    >
      <:actions>
        <.pill tone={:brand} size={:sm}>{@done_count}/{@total}</.pill>
        <.icon_button
          icon="hero-x-mark"
          label={dgettext("dashboard_home", "Dismiss setup checklist")}
          size={:sm}
          phx-click="onboarding:dismiss"
        />
      </:actions>

      <div class="h-2 w-full rounded-token-full bg-tymeslot-100 overflow-hidden mb-6">
        <div
          class="h-full rounded-token-full bg-linear-to-r from-turquoise-500 to-cyan-500 transition-all duration-500"
          style={"width: #{round(@done_count / @total * 100)}%"}
        >
        </div>
      </div>

      <ul class="space-y-3">
        <li :for={item <- @items}>
          <.item_row item={item} />
        </li>
      </ul>
    </.card>
    """
  end

  attr :item, :map, required: true

  defp item_row(assigns) do
    ~H"""
    <div
      data-setup-item={@item.key}
      class={[
        "flex flex-wrap items-center gap-3 sm:gap-4 p-4 rounded-token-2xl border-2 transition-all",
        if(@item.done,
          do: "bg-tymeslot-50/50 border-tymeslot-50",
          else:
            "bg-white border-turquoise-100 hover:border-turquoise-200 hover:shadow-lg hover:shadow-turquoise-500/5"
        )
      ]}
    >
      <%!-- Manual recommendations get a tick; deterministic provider items get
           none — they complete only from a real connection, so there is nothing
           to click. --%>
      <CheckToggle.check_toggle
        :if={@item.manual}
        id={"setup-toggle-#{@item.key}"}
        checked={@item.done}
        on_change="onboarding:toggle"
        phx_value_id={@item.key}
        label={
          if @item.done,
            do: dgettext("dashboard_home", "Mark %{title} as not done", title: @item.title),
            else: dgettext("dashboard_home", "Mark %{title} as done", title: @item.title)
        }
      />
      <span :if={not @item.manual} class="shrink-0 w-6" aria-hidden="true"></span>

      <div class={[
        "shrink-0 w-11 h-11 rounded-token-xl flex items-center justify-center shadow-sm transition-colors",
        if(@item.done,
          do: "bg-tymeslot-100 text-tymeslot-400",
          else: "bg-turquoise-50 text-turquoise-600"
        )
      ]}>
        <.icon name={@item.icon} class="w-6 h-6" />
      </div>

      <%!-- basis-0 keeps this column shrinking rather than pushing the action
           control onto the next line at desktop widths; the action's own
           `w-full` below `sm` is what forces the wrap on phones. --%>
      <div class="flex-1 basis-0 min-w-0">
        <div class={[
          "font-black tracking-tight text-balance",
          if(@item.done, do: "text-tymeslot-400", else: "text-tymeslot-900")
        ]}>
          {@item.title}
        </div>
        <%!-- Truncation only pays off once the action sits beside the text and
             the column is narrow; on phones the row is the description's own,
             so let it wrap rather than ellipsis away half the sentence. --%>
        <div class={[
          "text-token-sm font-bold sm:truncate",
          if(@item.done, do: "text-tymeslot-400", else: "text-tymeslot-500")
        ]}>
          {@item.description}
        </div>
      </div>

      <.item_cta item={@item} />
    </div>
    """
  end

  # Layout shared by every actionable variant below: full width on phones, so
  # the control drops onto its own line and leaves the title and description the
  # whole row; one fixed width from `sm` up, so the actions line up in a column.
  @cta_class "shrink-0 w-full sm:w-32"
  defp cta_class, do: @cta_class

  # The row's action: a static "Done" once the item is done, otherwise a link
  # to where it is completed.
  attr :item, :map, required: true

  # A status rather than an action, so it needs none of the button geometry —
  # only the same wrap behaviour, so a completed row lines up with the rest.
  defp item_cta(%{item: %{done: true}} = assigns) do
    ~H"""
    <span class="shrink-0 w-full sm:w-32 text-center text-token-xs font-black uppercase tracking-wider text-green-600">
      {dgettext("dashboard_home", "Done")}
    </span>
    """
  end

  defp item_cta(assigns) do
    ~H"""
    <.action_link patch={@item.path} size={:sm} class={cta_class() <> " group"}>
      {@item.cta}
      <.icon
        name="hero-arrow-right"
        class="inline-block w-4 h-4 align-text-bottom group-hover:translate-x-0.5 transition-transform"
      />
    </.action_link>
    """
  end

  # Merges live completion state onto the static catalogue, leaving out the
  # items this host is not offered. An item is done when its underlying state
  # is set or the host ticked it by hand; a stored tick for a key the
  # catalogue no longer holds matches nothing, so it neither shows nor counts.
  @spec items(map(), map(), map() | nil) :: [map()]
  defp items(integration_status, current_user, profile) do
    manual = current_user.dashboard_setup_done_items || []

    for item <- catalog(), offered?(item.key, profile) do
      if is_nil(item.auto) do
        # A hand-tickable item the host has already done is done without a
        # tick, and offers none: unticking it could not undo it.
        settled? = settled?(item.key, profile)
        Map.merge(item, %{manual: not settled?, done: settled? or item.key in manual})
      else
        # Deterministic items complete only from real state, never by hand.
        Map.merge(item, %{manual: false, done: Map.get(integration_status, item.auto, false)})
      end
    end
  end

  # A headline and bio are worth asking for only where a guest reads them.
  defp offered?("intro", %{booking_theme: theme_id}), do: Catalog.shows_intro?(theme_id)
  defp offered?("intro", _profile), do: false
  defp offered?(_key, _profile), do: true

  defp settled?(_key, nil), do: false
  defp settled?("avatar", profile), do: present?(profile.avatar)
  defp settled?("intro", profile), do: present?(profile.headline) or present?(profile.bio)
  defp settled?("embed", profile), do: Profiles.embedding_enabled?(profile)

  defp present?(value), do: is_binary(value) and value != ""

  # Static definition of the setup items. `auto` names the `integration_status`
  # key that completes the item automatically, or `nil` for manual-only items.
  #
  # The calendar stays first: until one is connected the booking page turns
  # every visitor away, so its description says that rather than selling sync.
  @spec catalog() :: [map()]
  defp catalog do
    [
      %{
        key: "calendar",
        auto: :calendar_ready,
        icon: "hero-calendar-days",
        title: dgettext("dashboard_home", "Connect a calendar"),
        description:
          dgettext("dashboard_home", "Your booking page can't take bookings without one"),
        cta: dgettext("dashboard_home", "Connect"),
        path: ~p"/dashboard/integrations?tab=calendars"
      },
      %{
        key: "video",
        auto: :has_video,
        icon: "hero-video-camera",
        title: dgettext("dashboard_home", "Add a video provider"),
        description: dgettext("dashboard_home", "Auto-add links to online meetings"),
        cta: dgettext("dashboard_home", "Connect"),
        path: ~p"/dashboard/integrations?tab=video"
      },
      %{
        key: "avatar",
        auto: nil,
        icon: "hero-camera",
        title: dgettext("dashboard_home", "Add your photo"),
        description: dgettext("dashboard_home", "Let guests see who they're meeting"),
        cta: dgettext("dashboard_home", "Add photo"),
        path: ~p"/dashboard/settings"
      },
      %{
        key: "intro",
        auto: nil,
        icon: "hero-chat-bubble-bottom-center-text",
        title: dgettext("dashboard_home", "Introduce yourself"),
        description: dgettext("dashboard_home", "Add a headline and a short bio"),
        cta: dgettext("dashboard_home", "Write"),
        path: ~p"/dashboard/settings"
      },
      %{
        key: "embed",
        auto: nil,
        icon: "hero-code-bracket",
        title: dgettext("dashboard_home", "Add it to your website"),
        description: dgettext("dashboard_home", "Let visitors book without leaving your site"),
        cta: dgettext("dashboard_home", "Set up"),
        path: ~p"/dashboard/embed"
      }
    ]
  end
end
