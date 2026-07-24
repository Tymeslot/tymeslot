defmodule TymeslotWeb.Dashboard.OnboardingChecklist do
  @moduledoc """
  Dashboard onboarding widget: a compact, dismissible checklist of recommended
  setup actions — connect a calendar, add video, customise the theme, review
  meeting types, share the booking page — each linking straight to where it is
  done.

  Two of the items complete themselves from real state (a connected calendar or
  video provider tick automatically); the rest, plus any the host wants to skip
  (e.g. video for in-person-only scheduling), can be ticked off by hand and grey
  out immediately. The whole widget can also be closed. Both the per-item ticks
  and the global close persist on the user via `Tymeslot.Onboarding`.

  Gate rendering on `visible?/2`: the widget hides once every item is done or the
  host has closed it, so a fully set-up user never sees it and no empty container
  is left behind. `toggleable_item?/1` lets the owning LiveView validate a toggled
  key at the event boundary before persisting it — deterministic provider items
  are rejected there, since they can only complete from a real connection.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Onboarding
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.Components.UI.CheckToggle
  alias TymeslotWeb.Endpoint

  @doc """
  Whether the widget should render for this host: not closed, and at least one
  setup item still outstanding.
  """
  @spec visible?(map(), map()) :: boolean()
  def visible?(current_user, integration_status) do
    not Onboarding.dashboard_setup_dismissed?(current_user) and
      Enum.any?(items(integration_status, current_user), &(not &1.done))
  end

  @doc """
  Whether `key` is an item the host may tick off by hand. Deterministic items —
  connecting a calendar or video provider — are excluded: they complete only
  from real state and can never be marked done manually.
  """
  @spec toggleable_item?(String.t()) :: boolean()
  def toggleable_item?(key), do: Enum.any?(catalog(), &(&1.key == key and is_nil(&1.auto)))

  attr :integration_status, :map, required: true
  attr :current_user, :map, required: true
  attr :profile, :any, required: true

  @spec onboarding_checklist(map()) :: Phoenix.LiveView.Rendered.t()
  def onboarding_checklist(assigns) do
    items =
      assigns.integration_status
      |> items(assigns.current_user)
      |> Enum.map(&with_copy_state(&1, assigns.integration_status, assigns.profile))

    assigns =
      assign(assigns,
        items: items,
        done_count: Enum.count(items, & &1.done),
        total: length(items)
      )

    ~H"""
    <section
      class="card-glass onboarding-checklist"
      data-testid="onboarding-checklist"
      data-tour="quick-actions"
      aria-label="Setup checklist"
      phx-remove={JS.transition("onboarding-checklist--leaving", time: 500)}
    >
      <div class="flex items-start justify-between gap-4 mb-6">
        <div class="min-w-0">
          <h2 class="text-token-xl font-black tracking-tight text-tymeslot-900">
            Finish setting up
          </h2>
          <p class="text-token-sm font-bold text-tymeslot-500 mt-1 text-pretty">
            A few recommended steps — tick off the ones you don't need.
          </p>
        </div>
        <div class="flex items-center gap-3 shrink-0">
          <span class="px-3 py-1 rounded-full bg-turquoise-50 text-turquoise-700 text-token-sm font-black tabular-nums">
            {@done_count}/{@total}
          </span>
          <button
            type="button"
            phx-click="onboarding:dismiss"
            aria-label="Dismiss setup checklist"
            class="w-8 h-8 flex items-center justify-center rounded-token-lg text-tymeslot-400 hover:text-tymeslot-600 hover:bg-tymeslot-100 transition-colors"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <div class="h-2 w-full rounded-full bg-tymeslot-100 overflow-hidden mb-6">
        <div
          class="h-full rounded-full bg-linear-to-r from-turquoise-500 to-cyan-500 transition-all duration-500"
          style={"width: #{round(@done_count / @total * 100)}%"}
        >
        </div>
      </div>

      <ul class="space-y-3">
        <li :for={item <- @items}>
          <.item_row item={item} />
        </li>
      </ul>
    </section>
    """
  end

  attr :item, :map, required: true

  defp item_row(assigns) do
    ~H"""
    <div class={[
      "flex flex-wrap items-center gap-3 sm:gap-4 p-4 rounded-token-2xl border-2 transition-all",
      if(@item.done,
        do: "bg-tymeslot-50/50 border-tymeslot-50",
        else: "bg-white border-turquoise-100 hover:border-turquoise-200 hover:shadow-lg hover:shadow-turquoise-500/5"
      )
    ]}>
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
          if @item.done, do: "Mark #{@item.title} as not done", else: "Mark #{@item.title} as done"
        }
      />
      <span :if={not @item.manual} class="shrink-0 w-6" aria-hidden="true"></span>

      <div class={[
        "shrink-0 w-11 h-11 rounded-token-xl flex items-center justify-center shadow-sm transition-colors",
        if(@item.done, do: "bg-tymeslot-100 text-tymeslot-400", else: "bg-turquoise-50 text-turquoise-600")
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

  # Geometry shared by every actionable variant below: full width on phones, so
  # the control drops onto its own line and leaves the title and description the
  # whole row; one fixed width from `sm` up, so the actions line up in a column.
  @cta_class "shrink-0 inline-flex items-center justify-center w-full sm:w-32 px-4 py-2 rounded-token-xl text-token-sm font-black transition-colors"
  defp cta_class, do: @cta_class

  # The row's action. A done item shows a static "Done"; the share item copies
  # the public booking link when the page is live (same readiness gate as the
  # sidebar) and greys out otherwise; every other item links to where it is
  # completed.
  attr :item, :map, required: true

  # A status rather than an action, so it needs none of the button geometry —
  # only the same wrap behaviour, so a completed row lines up with the rest.
  defp item_cta(%{item: %{done: true}} = assigns) do
    ~H"""
    <span class="shrink-0 w-full sm:w-32 text-center text-token-xs font-black uppercase tracking-wider text-emerald-600">
      Done
    </span>
    """
  end

  defp item_cta(%{item: %{action: :copy, shareable: true}} = assigns) do
    ~H"""
    <button
      type="button"
      id={"setup-copy-#{@item.key}"}
      phx-hook="CopyOnClick"
      data-copy-text={@item.copy_url}
      data-copy-feedback="Booking link copied to clipboard!"
      class={[cta_class(), "gap-1.5 bg-turquoise-600 hover:bg-turquoise-700 text-white"]}
    >
      <.icon name="hero-clipboard" class="w-4 h-4" /> {@item.cta}
    </button>
    """
  end

  defp item_cta(%{item: %{action: :copy}} = assigns) do
    ~H"""
    <span
      class={[cta_class(), "gap-1.5 bg-tymeslot-100 text-tymeslot-400 cursor-not-allowed"]}
      title={@item.disabled_tooltip}
    >
      <.icon name="hero-clipboard" class="w-4 h-4" /> {@item.cta}
    </span>
    """
  end

  defp item_cta(assigns) do
    ~H"""
    <.link
      patch={@item.path}
      class={[cta_class(), "gap-1 bg-turquoise-600 hover:bg-turquoise-700 text-white group"]}
    >
      {@item.cta} <span class="group-hover:translate-x-0.5 transition-transform">→</span>
    </.link>
    """
  end

  # Attaches the share item's live copy state. When the booking page is ready
  # (same `LinkAccessPolicy` gate the sidebar uses) it carries the full link to
  # copy; otherwise it carries the reason it is disabled. Other items pass through.
  @spec with_copy_state(map(), map(), map() | nil) :: map()
  defp with_copy_state(%{action: :copy} = item, integration_status, profile) do
    if LinkAccessPolicy.can_link?(profile, integration_status) do
      Map.merge(item, %{
        shareable: true,
        copy_url: Endpoint.url() <> LinkAccessPolicy.scheduling_path(profile)
      })
    else
      Map.merge(item, %{
        shareable: false,
        disabled_tooltip: LinkAccessPolicy.disabled_tooltip(profile, integration_status)
      })
    end
  end

  defp with_copy_state(item, _integration_status, _profile), do: item

  # Merges live completion state onto the static catalogue. An item is done when
  # its underlying state is set (`auto_done`) or the host ticked it by hand.
  @spec items(map(), map()) :: [map()]
  defp items(integration_status, current_user) do
    manual = current_user.dashboard_setup_done_items || []

    Enum.map(catalog(), fn item ->
      manual? = is_nil(item.auto)
      # Deterministic items complete only from real state; manual ones only from
      # the host's own ticks — the two never mix.
      done =
        if manual?, do: item.key in manual, else: Map.get(integration_status, item.auto, false)

      Map.merge(item, %{manual: manual?, done: done})
    end)
  end

  # Static definition of the setup items. `auto` names the `integration_status`
  # key that completes the item automatically, or `nil` for manual-only items.
  @spec catalog() :: [map()]
  defp catalog do
    [
      %{
        key: "calendar",
        auto: :has_calendar,
        icon: "hero-calendar-days",
        title: "Connect a calendar",
        description: "Sync to avoid double-bookings",
        cta: "Connect",
        path: ~p"/dashboard/integrations?tab=calendars"
      },
      %{
        key: "video",
        auto: :has_video,
        icon: "hero-video-camera",
        title: "Add a video provider",
        description: "Auto-add links to online meetings",
        cta: "Connect",
        path: ~p"/dashboard/integrations?tab=video"
      },
      %{
        key: "theme",
        auto: nil,
        icon: "hero-paint-brush",
        title: "Customise your theme",
        description: "Make your booking page yours",
        cta: "Customise",
        path: ~p"/dashboard/theme"
      },
      %{
        key: "meeting_types",
        auto: nil,
        icon: "hero-squares-2x2",
        title: "Review your meeting types",
        description: "Tune durations and questions",
        cta: "Review",
        path: ~p"/dashboard/meeting-settings"
      },
      %{
        key: "share",
        auto: nil,
        action: :copy,
        icon: "hero-arrow-top-right-on-square",
        title: "Share your booking page",
        description: "Send guests your booking link",
        cta: "Copy link"
      }
    ]
  end
end
