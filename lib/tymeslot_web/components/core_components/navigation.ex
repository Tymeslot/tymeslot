defmodule TymeslotWeb.Components.CoreComponents.Navigation do
  @moduledoc "Navigation components: definition rows, tab strips and segmented controls."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.Icons.IconComponents

  # ========== NAVIGATION ==========

  @doc """
  Renders a detail row for definition lists.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true

  @spec detail_row(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_row(assigns) do
    ~H"""
    <div class="flex justify-between">
      <dt style="color: rgba(255,255,255,0.7);">{@label}:</dt>
      <dd class="font-medium" style="color: white;">{@value}</dd>
    </div>
    """
  end

  # The fade a sideways-scrolling strip shows on an edge with more content
  # beyond it. The `ScrollStrip` hook sets `data-overflow` to `start`, `end` or
  # `both` while something is clipped and removes it otherwise, so a strip that
  # fits shows no fade at all. The scrollbar itself is hidden: the fade is the
  # affordance, and a bar under a row of pills reads as a rendering fault.
  @scroll_strip [
    "flex-nowrap overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
    "data-[overflow=end]:[mask-image:linear-gradient(to_right,black_calc(100%_-_2.5rem),transparent)]",
    "data-[overflow=start]:[mask-image:linear-gradient(to_left,black_calc(100%_-_2.5rem),transparent)]",
    "data-[overflow=both]:[mask-image:linear-gradient(to_right,transparent,black_2.5rem,black_calc(100%_-_2.5rem),transparent)]"
  ]

  @doc """
  Renders a tab strip: the one look for every set of tabs in the dashboard.

  The entries decide which of two kinds of tab it is:

    * **Panel tabs** switch content in place. The strip is a `role="tablist"`
      of `role="tab"` buttons with `aria-selected`; the selected one also
      carries `aria-controls`, naming its panel. The caller renders the
      panels, so they can live wherever the layout needs them (inside one
      shared `<form>`, say), each with `role="tabpanel"`,
      `id={panel_id(strip_id, tab_id)}` and
      `aria-labelledby={tab_id(strip_id, tab_id)}`. A caller may render only
      the selected panel; `aria-controls` names only that one, so it never
      points at an element that is not there. Only the selected tab is in the
      tab order; the arrow keys, Home and End move between the tabs and select
      them (the `ScrollStrip` hook). A click pushes `event` to `target` with
      the tab id under `"tab"`.
    * **Link tabs**, whose entries carry `:patch` or `:navigate`, change the
      URL. They render as links in a `<nav>`, the current one marked
      `aria-current="page"`: a list of routes is navigation, not a tablist.
      A strip is one kind or the other; mixing them raises.

  Tab and panel ids are scoped to the strip's `id` (`tab_id/2`, `panel_id/2`),
  so two strips on one page never share an element id.

  Each entry is a map with `:id` and `:label`, and optionally:

    * `:icon`: a `hero-…` name, or a brand-mark atom for `IconComponents.icon/1`
    * `:count`: a number shown in a small pill after the label
    * `:badge`: a short word in a neutral pill, such as "Disabled"
    * `:status` and `:status_label`: a pill tone (`:warning`, `:danger`, …)
      shown as a dot in that tone's colour, the same dot `Feedback.pill/1`
      uses, with `:status_label` read to screen readers in its place
    * `:error`: shorthand for a `:danger` status saying the tab has errors
    * `:disabled`: shown, but cannot be selected
    * `:describedby`: the id of an element saying more about the tab, set as
      the panel tab's `aria-describedby`; typically why a disabled tab is
      disabled, since a disabled button cannot carry a tooltip
    * `:accent` and `:dot`: for tabs that stand for differently coloured
      things, classes used in place of the default active styling, and a
      background class for a disc shown while the tab is inactive

  On a narrow screen the strip stays a single row and scrolls sideways,
  fading whichever edge has more tabs beyond it, rather than wrapping into a
  ragged block. A strip whose tabs open a menu (`tab_action`) passes
  `overflow={:wrap}` instead, because a scrolling row clips anything that
  drops out of it.
  """
  attr :id, :string, required: true, doc: "id of the strip; the hook needs one"
  attr :active_tab, :any, required: true, doc: "id of the selected tab, or nil for none"
  attr :target, :any, default: nil

  attr :tabs, :list,
    required: true,
    doc: "maps with :id and :label; see the moduledoc for the optional keys"

  attr :event, :string,
    default: "switch_tab",
    doc: "event pushed on click by panel tabs, with the tab id under \"tab\""

  attr :aria_label, :string, required: true, doc: "what the tabs choose between"

  attr :variant, :atom,
    default: :card,
    values: [:card, :attached],
    doc: """
    `:card` is a standalone rounded bar. `:attached` drops the shell's own
    rounding, shadow and background so the strip reads as the top edge of the
    panel a caller wraps around it; that caller supplies the tint and rule
    colour through `class`.
    """

  attr :size, :atom,
    default: :md,
    values: [:md, :sm],
    doc: "`:sm` for a strip inside a card or beside other controls"

  attr :overflow, :atom,
    default: :scroll,
    values: [:scroll, :wrap],
    doc: "how the strip behaves when its tabs do not fit on one row"

  attr :class, :string,
    default: nil,
    doc: "extra classes for the shell, applied after the variant's own"

  slot :trailing,
    doc: """
    Controls rendered beside the tabs, such as an "add" affordance. Rendered
    outside the `tablist`, since ARIA expects a tablist to contain only tabs.
    """

  slot :tab_action,
    doc: """
    A control rendered inside the active tab, sharing its pill: a menu whose
    actions belong to that tab and nowhere else. Receives the tab map, and is
    rendered only for the active one. It cannot be nested in the tab `<button>`
    itself, so both sit in a wrapper marked `role="presentation"`, which keeps
    the button the tablist's only meaningful child.
    """

  @spec tab_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def tab_bar(assigns) do
    assigns =
      assign(assigns,
        links?: links?(assigns.tabs, assigns.id),
        focus_id: focus_id(assigns.tabs, assigns.active_tab)
      )

    ~H"""
    <div class={[
      "p-1",
      shell_class(@variant),
      @trailing != [] && "flex flex-wrap items-center gap-2",
      @class
    ]}>
      <.dynamic_tag
        tag_name={if @links?, do: "nav", else: "div"}
        id={@id}
        role={!@links? && "tablist"}
        aria-label={@aria_label}
        phx-hook="ScrollStrip"
        class={[
          "flex gap-2 p-1",
          strip_class(@overflow),
          @trailing != [] && "grow min-w-0"
        ]}
      >
        <div
          :for={tab <- @tabs}
          role={!@links? && "presentation"}
          class={[
            "flex items-center rounded-token-xl transition-colors duration-300",
            tab_fit_class(@overflow),
            tab_state_class(tab, tab.id == @active_tab)
          ]}
        >
          <.link
            :if={@links?}
            id={tab_id(@id, tab.id)}
            navigate={tab[:navigate]}
            patch={tab[:patch]}
            aria-current={tab.id == @active_tab && "page"}
            class={tab_class(@size, false)}
          >
            <.tab_content tab={tab} active={tab.id == @active_tab} />
          </.link>

          <button
            :if={!@links?}
            type="button"
            role="tab"
            id={tab_id(@id, tab.id)}
            aria-selected={to_string(tab.id == @active_tab)}
            aria-controls={tab.id == @active_tab && panel_id(@id, tab.id)}
            tabindex={if tab.id == @focus_id, do: "0", else: "-1"}
            disabled={tab[:disabled]}
            aria-describedby={tab[:describedby]}
            phx-click={@event}
            phx-value-tab={tab.id}
            phx-target={@target}
            class={tab_class(@size, @tab_action != [] && tab.id == @active_tab)}
          >
            <.tab_content tab={tab} active={tab.id == @active_tab} />
          </button>

          <div :if={@tab_action != [] && tab.id == @active_tab} class="pr-2">
            {render_slot(@tab_action, tab)}
          </div>
        </div>
      </.dynamic_tag>

      <div :if={@trailing != []} class="flex items-center gap-2 shrink-0">
        {render_slot(@trailing)}
      </div>
    </div>
    """
  end

  attr :tab, :map, required: true
  attr :active, :boolean, required: true

  defp tab_content(assigns) do
    assigns = assign(assigns, :status, tab_status(assigns.tab))

    ~H"""
    <.strip_icon :if={@tab[:icon]} icon={@tab.icon} class="w-5 h-5" />
    <span
      :if={@tab[:dot] && !@active}
      class={["w-2.5 h-2.5 shrink-0 rounded-token-full", @tab.dot]}
    ></span>
    <span class="truncate">{@tab.label}</span>
    <.count_badge :if={@tab[:count]} count={@tab.count} active={@active} />
    <Feedback.pill :if={@tab[:badge]}>{@tab.badge}</Feedback.pill>
    <span :if={@status} class="inline-flex shrink-0 items-center">
      <span
        class={["w-2 h-2 shrink-0 rounded-token-full", Feedback.pill_dot_class(elem(@status, 0))]}
        aria-hidden="true"
      ></span>
      <span class="sr-only">{elem(@status, 1)}</span>
    </span>
    """
  end

  @doc "The element id of the tab `tab_id` in the strip `strip_id`."
  @spec tab_id(String.t(), term()) :: String.t()
  def tab_id(strip_id, tab_id), do: "#{strip_id}-tab-#{tab_id}"

  @doc """
  The element id the panel of the tab `tab_id` in the strip `strip_id` must
  carry, which the selected tab's `aria-controls` names.
  """
  @spec panel_id(String.t(), term()) :: String.t()
  def panel_id(strip_id, tab_id), do: "#{strip_id}-panel-#{tab_id}"

  # A strip is all links or all panel tabs: a link among tablist buttons would
  # sit in a tablist as navigation, which no assistive technology can describe.
  defp links?(tabs, strip_id) do
    case Enum.split_with(tabs, &link_tab?/1) do
      {[], _panel_tabs} ->
        false

      {_link_tabs, []} ->
        true

      _mixed ->
        raise ArgumentError,
              "tab_bar #{inspect(strip_id)} mixes link tabs (:patch or :navigate) " <>
                "with panel tabs; use one kind per strip"
    end
  end

  defp link_tab?(tab), do: Map.has_key?(tab, :patch) or Map.has_key?(tab, :navigate)

  # Which tab takes the strip's single tab stop: the selected one, or the
  # first that can be selected when none is (a page with nothing chosen
  # yet must still be reachable from the keyboard).
  defp focus_id(tabs, active_tab) do
    selectable = Enum.reject(tabs, & &1[:disabled])

    case Enum.find(selectable, &(&1.id == active_tab)) || List.first(selectable) do
      nil -> nil
      tab -> tab.id
    end
  end

  defp tab_status(%{status: tone, status_label: label}) when is_atom(tone) and tone != nil,
    do: {tone, label}

  defp tab_status(%{error: true}),
    do: {:danger, dgettext("common", "This tab contains errors")}

  defp tab_status(_tab), do: nil

  defp tab_state_class(%{disabled: true}, _active),
    do: "text-tymeslot-400 opacity-60 cursor-not-allowed"

  defp tab_state_class(tab, true),
    do:
      tab[:accent] ||
        "bg-linear-to-r from-turquoise-600 to-cyan-600 text-white shadow-md shadow-turquoise-500/30"

  defp tab_state_class(_tab, false),
    do: "text-tymeslot-600 hover:bg-tymeslot-50 hover:text-turquoise-700"

  defp tab_class(size, with_action?) do
    [
      "flex min-w-0 items-center gap-2 whitespace-nowrap rounded-token-xl font-bold text-token-sm",
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400 disabled:cursor-not-allowed",
      tab_padding(size),
      with_action? && "pr-2 sm:pr-3"
    ]
  end

  defp tab_padding(:md), do: "px-4 py-2.5 sm:px-6 sm:py-3"
  defp tab_padding(:sm), do: "px-3 py-2"

  defp shell_class(:card),
    do: "bg-white rounded-token-2xl border-2 border-tymeslot-100 shadow-sm"

  defp shell_class(:attached), do: "border-b-2"

  # A scrolling row keeps every tab whole and scrolls instead. A wrapping one
  # lets a tab narrower than its label shrink to the row and truncate the
  # label, so one long name cannot run under whatever sits beside it.
  defp tab_fit_class(:scroll), do: "shrink-0"
  defp tab_fit_class(:wrap), do: "min-w-0 max-w-full"

  defp strip_class(:scroll), do: @scroll_strip
  defp strip_class(:wrap), do: "flex-wrap"

  @doc """
  Renders a segmented control: a short row of mutually exclusive options, one
  of which is always chosen, such as a date range or a calendar view.

  It is a group of toggle buttons (`role="group"` labelled by `aria_label`,
  each option a `type="button"` with `aria-pressed`) rather than a radio group
  or a tablist: every option is its own tab stop and needs no script, and
  choosing one changes what the page below shows without being a separate
  panel of it. Use `tab_bar/1` for that.

  Choosing an option pushes `on_change` to `target` with the option's value
  under `param` (default `"value"`), so an existing handler keeps its
  parameter name. Each button has the id `<id>-<value>`.

  Options take a `label`, and optionally an `icon` (`hero-…`; shown from the
  `sm` breakpoint up, so a phone gets the labels alone), a `count` shown in a
  small pill (amber while inactive when the option is marked `attention`), a
  `testid` and `disabled`. Content inside an option renders after its label.

  On a narrow screen the row scrolls sideways, fading the clipped edge,
  instead of wrapping. It may shrink below its content (`min-w-0`), so beside
  a label in a flex row it scrolls rather than pushing the label aside. Focus
  rings are drawn inside each option, where the scrolling row cannot clip them.
  """
  attr :id, :string, required: true
  attr :value, :any, required: true, doc: "the chosen option's value"
  attr :on_change, :any, required: true, doc: "event pushed when an option is chosen"
  attr :param, :string, default: "value", doc: "the parameter the chosen value is sent under"
  attr :target, :any, default: nil
  attr :aria_label, :string, required: true, doc: "what the options choose"
  attr :size, :atom, default: :md, values: [:sm, :md]
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil, doc: "layout classes for the group"

  slot :option, required: true do
    attr :value, :any, required: true
    attr :label, :string, required: true
    attr :icon, :string
    attr :count, :integer
    attr :attention, :boolean
    attr :disabled, :boolean
    attr :testid, :string
  end

  @spec segmented_control(map()) :: Phoenix.LiveView.Rendered.t()
  def segmented_control(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-label={@aria_label}
      phx-hook="ScrollStrip"
      class={[
        "inline-flex min-w-0 max-w-full gap-0.5 rounded-token-lg border border-tymeslot-200 bg-white p-0.5",
        strip_class(:scroll),
        @class
      ]}
    >
      <button
        :for={option <- @option}
        type="button"
        id={"#{@id}-#{option.value}"}
        aria-pressed={to_string(chosen?(option, @value))}
        disabled={@disabled || option[:disabled]}
        data-testid={option[:testid]}
        phx-click={@on_change}
        phx-target={@target}
        {%{"phx-value-#{@param}" => to_string(option.value)}}
        class={[
          "inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-token-md font-semibold transition-colors",
          "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-turquoise-400",
          "disabled:cursor-not-allowed disabled:opacity-50",
          segment_size_class(@size),
          if(chosen?(option, @value),
            do: "bg-turquoise-600 text-white shadow-sm",
            else: "text-tymeslot-600 hover:bg-tymeslot-50 hover:text-tymeslot-900"
          )
        ]}
      >
        <.strip_icon :if={option[:icon]} icon={option.icon} class="hidden sm:block w-4 h-4" />
        <span>{option.label}</span>
        <.count_badge
          :if={option[:count]}
          count={option.count}
          active={chosen?(option, @value)}
          attention={option[:attention] || false}
        />
        {option.inner_block && render_slot(option)}
      </button>
    </div>
    """
  end

  defp chosen?(option, value), do: to_string(option.value) == to_string(value)

  defp segment_size_class(:sm), do: "px-2.5 py-1 text-token-xs"
  defp segment_size_class(:md), do: "px-3 py-1.5 text-token-sm"

  attr :count, :integer, required: true
  attr :active, :boolean, required: true
  attr :attention, :boolean, default: false

  defp count_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center justify-center min-w-5 h-5 px-1.5 rounded-token-full text-token-xs font-bold tabular-nums",
      cond do
        @active -> "bg-white/25 text-white"
        @attention -> "bg-amber-100 text-amber-700"
        true -> "bg-tymeslot-100 text-tymeslot-600"
      end
    ]}>
      {@count}
    </span>
    """
  end

  attr :icon, :any, required: true
  attr :class, :string, required: true

  defp strip_icon(%{icon: icon} = assigns) when is_atom(icon) do
    ~H"""
    <IconComponents.icon name={@icon} class={"shrink-0 #{@class}"} />
    """
  end

  defp strip_icon(assigns) do
    ~H"""
    <Icons.icon name={@icon} class={"shrink-0 #{@class}"} />
    """
  end
end
