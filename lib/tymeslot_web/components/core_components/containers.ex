defmodule TymeslotWeb.Components.CoreComponents.Containers do
  @moduledoc "Container and display components extracted from CoreComponents."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.Icons.IconComponents

  # ========== CARDS & CONTAINERS ==========

  @card_variants %{
    glass: nil,
    flat: "card-glass--flat",
    muted: "card-glass--muted"
  }

  @card_paddings %{
    none: "p-0",
    xs: "px-4 py-3",
    sm: "p-4",
    md: "p-6",
    lg: "p-6 sm:p-8"
  }

  @doc """
  Renders a dashboard card: the white surface every settings section and list
  sits on.

      <.card title="Booking limits" icon="hero-clock" description="Caps across every type">
        <:actions><.action_button size={:sm}>Reset</.action_button></:actions>
        ...
      </.card>

  * `variant`: `:glass` (the default, a lifted card on the page), `:flat` (the
    same surface without the shadow, for a card inside another card or a row
    in a list), `:muted` (a recessed tinted surface).
  * `padding`: `:none`, `:xs` (a compact list row), `:sm`, `:md` (the
    default) or `:lg`.
  * `interactive`: the whole card is clickable, so it shows a pointer and
    reacts to hover. Static cards do not.
  * `title` renders the card heading (an `<h2>` at the card-title scale) with
    an optional `icon` and `description`; the `:header` slot replaces it with
    custom content, and `:actions` sits at the header's end.

  `class` is for layout and state (margins, `space-y-*`, a selected ring), not
  for restyling the surface.
  """
  attr :variant, :atom, default: :glass, values: Map.keys(@card_variants)
  attr :padding, :atom, default: :md, values: Map.keys(@card_paddings)
  attr :interactive, :boolean, default: false
  attr :tag, :string, default: "div", values: ~w(div section article aside li label)
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :icon, :string, default: nil, doc: "A `hero-…` icon beside the title"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(for)

  slot :header, doc: "Custom header content, in place of `title`, `icon` and `description`"
  slot :actions, doc: "Controls at the end of the header row"
  slot :inner_block

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    assigns =
      assign(assigns,
        variant_class: Map.fetch!(@card_variants, assigns.variant),
        padding_class: Map.fetch!(@card_paddings, assigns.padding),
        header?: assigns.title != nil or assigns.header != [] or assigns.actions != []
      )

    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      class={[
        "card-glass",
        @variant_class,
        @padding_class,
        @interactive && "card-glass--interactive",
        @class
      ]}
      {@rest}
    >
      <div :if={@header?} class="mb-6 flex flex-wrap items-start justify-between gap-x-4 gap-y-3">
        <div class="min-w-0 flex-1">
          <%= if @header != [] do %>
            {render_slot(@header)}
          <% else %>
            <.subsection_header
              :if={@title}
              size={:lg}
              level={2}
              icon={@icon}
              title={@title}
              description={@description}
            />
          <% end %>
        </div>
        <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  @subsection_sizes %{
    md: %{title: "text-token-base text-tymeslot-800", icon: "h-5 w-5"},
    lg: %{title: "text-token-lg text-tymeslot-900", icon: "h-6 w-6"}
  }

  @doc """
  Renders the heading of a part of a settings card or form: an optional icon,
  the title and an optional description, with actions at the end.

      <.subsection_header icon="hero-bell" title="Reminders" description="..." />

  Headings across the dashboard share one weight (semibold) on two sizes:
  `:md` (the default) for a subsection inside a card, `:lg` for a card's own
  title, which is what `<.card title>` renders. `level` sets the heading tag
  only, so the outline stays right wherever the header sits.

  Give it an `id` when the heading is what labels a control
  (`aria-labelledby`); the heading carries the id.
  """
  attr :title, :string, required: true
  attr :icon, :string, default: nil, doc: "A `hero-…` icon before the title"
  attr :description, :string, default: nil
  attr :size, :atom, default: :md, values: Map.keys(@subsection_sizes)
  attr :level, :integer, default: 3, values: [2, 3, 4]
  attr :id, :string, default: nil, doc: "The heading's id"
  attr :class, :any, default: nil, doc: "Layout classes only"
  slot :actions

  @spec subsection_header(map()) :: Phoenix.LiveView.Rendered.t()
  def subsection_header(assigns) do
    assigns = assign(assigns, :sizing, Map.fetch!(@subsection_sizes, assigns.size))

    ~H"""
    <div class={["flex flex-wrap items-start justify-between gap-x-4 gap-y-2", @class]}>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <Icons.icon
            :if={@icon}
            name={@icon}
            class={"shrink-0 text-turquoise-500 #{@sizing.icon}"}
          />
          <.dynamic_tag
            tag_name={"h#{@level}"}
            id={@id}
            class={["min-w-0 break-words font-semibold", @sizing.title]}
          >
            {@title}
          </.dynamic_tag>
        </div>
        <p :if={@description} class="mt-1 text-token-sm text-tymeslot-600">{@description}</p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a glass-morphism card container.
  """
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec glass_morphism_card(map()) :: Phoenix.LiveView.Rendered.t()
  def glass_morphism_card(assigns) do
    ~H"""
    <div class={["glass-morphism-card", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a generic detail card with consistent styling.
  """
  attr :title, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec detail_card(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_card(assigns) do
    ~H"""
    <div class={["meeting-details-card", @class]}>
      <%= if @title do %>
        <h3 class="text-xl font-black mb-4 text-tymeslot-900 tracking-tight">{@title}</h3>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders an icon badge with gradient background.

  Accepts either a `hero-…` icon name via the `icon` attribute, rendered
  through `<.icon>`, or raw SVG child markup (e.g. `<path>`) via the default
  slot, drawn inside the badge's own `<svg>` wrapper. `<.icon>` renders a
  complete `<svg>` of its own, so it must never be passed as slot content —
  that nests one `<svg>` inside another.
  """
  attr :size, :atom, default: :medium, values: [:small, :medium, :large]
  attr :icon, :string, default: nil, doc: "A `hero-…` icon name, rendered via `<.icon>`"
  attr :class, :string, default: ""
  slot :inner_block, doc: "Raw SVG children (e.g. `<path>`), used when `icon` is not given"

  @spec icon_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_badge(assigns) do
    size_classes =
      case assigns.size do
        :small -> "h-12 w-12"
        :large -> "h-24 w-24"
        _other -> "h-16 w-16"
      end

    icon_size =
      case assigns.size do
        :small -> "h-6 w-6"
        :large -> "h-12 w-12"
        _other -> "h-8 w-8"
      end

    assigns = assigns |> assign(:size_classes, size_classes) |> assign(:icon_size, icon_size)

    ~H"""
    <div class={[
      "mx-auto flex items-center justify-center #{@size_classes} rounded-3xl mb-6 bg-linear-to-br from-turquoise-600 to-cyan-600 shadow-xl shadow-turquoise-500/20 border-4 border-white transform transition-transform hover:scale-110",
      @class
    ]}>
      <Icons.icon :if={@icon} name={@icon} class={"#{@icon_size} text-white"} />
      <svg
        :if={!@icon}
        class={"#{@icon_size} text-white"}
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
        stroke-width="2.5"
      >
        {render_slot(@inner_block)}
      </svg>
    </div>
    """
  end

  @doc """
  Renders a section header with consistent styling. Supports optional icon, count badge, and saving indicator.
  """
  attr :icon, :any,
    default: nil,
    doc: "A `hero-…` icon name (string) or a brand-mark atom (e.g. `:webhook`)"

  attr :title, :string, default: nil
  attr :count, :integer, default: nil
  attr :saving, :boolean, default: false
  attr :level, :integer, default: 1
  attr :title_class, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block

  @spec section_header(map()) :: Phoenix.LiveView.Rendered.t()
  def section_header(assigns) do
    size_class =
      case assigns.level do
        1 -> "text-4xl"
        2 -> "text-3xl"
        3 -> "text-2xl"
        _other -> "text-xl"
      end

    computed_title_class =
      assigns.title_class || "#{size_class} font-black text-tymeslot-900 tracking-tight"

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:computed_title_class, computed_title_class)

    ~H"""
    <div :if={@icon} class={["flex items-center mb-4", @class]}>
      <div class="w-14 h-14 bg-white rounded-2xl flex items-center justify-center mr-5 shadow-sm border border-tymeslot-100 shrink-0">
        <%!-- Hero icons arrive as `hero-…` strings; the few brand marks with no
             Heroicon equivalent (e.g. `:webhook`) arrive as atoms. --%>
        <Icons.icon :if={is_binary(@icon)} name={@icon} class="w-8 h-8 text-turquoise-600" />
        <IconComponents.icon :if={is_atom(@icon)} name={@icon} class="w-8 h-8 text-turquoise-600" />
      </div>

      <h1 class={@computed_title_class}>
        <%= if @title do %>
          {@title}
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </h1>

      <%= if @count do %>
        <span class="ml-4 bg-turquoise-100 text-turquoise-700 text-xs font-black px-3 py-1 rounded-full uppercase tracking-wider">
          {@count}
        </span>
      <% end %>

      <%= if @saving do %>
        <div class="ml-auto bg-emerald-50 text-emerald-700 px-4 py-2 rounded-full font-black text-xs uppercase tracking-wider border-2 border-emerald-100 flex items-center">
          <Feedback.spinner class="h-4 w-4 mr-2" />
          {dgettext("common", "Saving changes...")}
        </div>
      <% end %>
    </div>

    <h1 :if={!@icon} class={[@computed_title_class, "mb-2", @class]}>
      <%= if @title do %>
        {@title}
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </h1>
    """
  end

  @detail_tiles %{
    brand: "bg-turquoise-50 border-turquoise-100 text-turquoise-600",
    info: "bg-blue-50 border-blue-100 text-blue-600",
    danger: "bg-red-50 border-red-100 text-red-500"
  }

  @doc """
  One line of details: an icon beside an optional label, over the value in the
  inner block.

      <.detail_line icon="hero-clock" label="Time">2:30 PM – 3:00 PM</.detail_line>

  * `:default`: a brand icon, an uppercase label and a bold value. Detail modals.
  * `:compact`: a small muted icon beside free content (text, inputs, pickers),
    with a quiet label when given. Rows of an editable form.
  * `:tile`: the icon in a square tinted by `tone`, for cards with room to spare.
    `tone` applies to this variant only.
  """
  attr :icon, :string, required: true
  attr :label, :string, default: nil
  attr :variant, :atom, default: :default, values: [:default, :compact, :tile]

  attr :tone, :atom,
    default: :brand,
    values: Map.keys(@detail_tiles),
    doc: "The tile's tint; `:tile` only, the other variants ignore it"

  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global
  slot :inner_block, required: true

  @spec detail_line(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_line(%{variant: :tile} = assigns) do
    assigns = assign(assigns, :tile_class, Map.fetch!(@detail_tiles, assigns.tone))

    ~H"""
    <div class={["flex items-center gap-4", @class]} {@rest}>
      <div class={[
        "w-12 h-12 shrink-0 rounded-token-2xl border shadow-sm flex items-center justify-center",
        @tile_class
      ]}>
        <Icons.icon name={@icon} class="w-6 h-6" />
      </div>
      <div class="min-w-0">
        <p
          :if={@label}
          class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-0.5"
        >
          {@label}
        </p>
        <div class="text-tymeslot-700 font-bold break-words">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  def detail_line(%{variant: :compact} = assigns) do
    ~H"""
    <div class={["flex items-start gap-3", @class]} {@rest}>
      <Icons.icon name={@icon} class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" />
      <div class="min-w-0 flex-1">
        <p :if={@label} class="text-token-xs font-medium text-tymeslot-400 mb-1.5">{@label}</p>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  def detail_line(assigns) do
    ~H"""
    <div class={["flex items-start gap-3", @class]} {@rest}>
      <Icons.icon name={@icon} class="w-5 h-5 text-turquoise-500 shrink-0 mt-0.5" />
      <div class="min-w-0 flex-1">
        <p :if={@label} class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400">
          {@label}
        </p>
        <div class="mt-0.5 text-tymeslot-800 font-bold break-words">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  @doc """
  Renders an info/alert box.
  """
  attr :variant, :atom, default: :info, values: [:info, :success, :warning, :error]
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec info_box(map()) :: Phoenix.LiveView.Rendered.t()
  def info_box(assigns) do
    classes =
      case assigns.variant do
        :success -> "bg-emerald-50 border-emerald-200 text-emerald-800"
        :warning -> "bg-amber-50 border-amber-200 text-amber-800"
        :error -> "bg-red-50 border-red-200 text-red-800"
        :info -> "bg-sky-50 border-sky-200 text-sky-800"
        _other -> "bg-tymeslot-50 border-tymeslot-200 text-tymeslot-800"
      end

    assigns = assign(assigns, :classes, classes)

    ~H"""
    <div class={["rounded-2xl p-6 mb-8 border-2", @classes, @class]}>
      <p class="font-medium">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end
end
