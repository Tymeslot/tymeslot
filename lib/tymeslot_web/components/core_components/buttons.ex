defmodule TymeslotWeb.Components.CoreComponents.Buttons do
  @moduledoc """
  Button components extracted from CoreComponents.

  `action_button/1` and `action_link/1` share one look: the same variants and
  sizes, so a control that navigates and one that pushes an event sit side by
  side without drifting apart. `icon_button/1` is the square, icon-only
  sibling, and always carries an accessible label.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  # Application modules
  alias TymeslotWeb.Components.CoreComponents.Feedback, as: Feedback
  alias TymeslotWeb.Components.CoreComponents.Icons, as: Icons
  alias TymeslotWeb.Components.CoreComponents.Tooltip, as: Tooltip

  @variants [:primary, :secondary, :danger, :danger_soft, :outline, :ghost, :success, :on_dark]
  @sizes [:sm, :md, :lg]
  @icon_variants [:neutral, :danger, :warning]
  @icon_sizes [:sm, :md]

  # ========== BUTTONS ==========

  @doc """
  Renders an action button.

  ## Options
    * `:variant` - `:primary` (filled brand gradient, the one main action),
      `:secondary` (white, outlined), `:danger` (solid red; reserve it for the
      confirm button of a destructive confirmation), `:danger_soft` (red text and
      outline, no fill; a destructive action sitting beside a primary one),
      `:outline` (transparent, outlined), `:ghost` (no border or fill),
      `:success` (green gradient, an additive action) and `:on_dark` (white, for
      a button on a dark or brand-coloured surface). Defaults to `:primary`
    * `:size` - `:sm`, `:md` or `:lg`. Defaults to `:md`
    * `:icon` - A leading `hero-…` icon name
    * `:type` - Button type attribute. Defaults to "button"
    * `:disabled` - Whether the button is disabled. Defaults to false
    * `:tooltip` - Text shown on hover and keyboard focus and linked by
      `aria-describedby` (so the button needs an `id`). With `disabled`, it is
      the reason the button is unavailable: the button then renders
      `aria-disabled` instead, so it stays focusable to explain itself, and its
      `phx-click` is dropped so it cannot fire
    * `:class` - Additional CSS classes (layout only: width, margins)
  """
  attr :variant, :atom, default: :primary, values: @variants
  attr :size, :atom, default: :md, values: @sizes
  attr :icon, :string, default: nil, doc: "A leading `hero-…` icon name"
  attr :type, :string, default: "button"
  attr :form, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :tooltip, :any, default: nil, doc: "see the `:tooltip` option above"
  attr :class, :any, default: ""
  # `name` and `value` let one of several submit buttons say which it was.
  attr :rest, :global, include: ~w(name value)

  slot :inner_block, required: true

  @spec action_button(map()) :: Phoenix.LiveView.Rendered.t()
  def action_button(assigns) do
    assigns = assign_availability(assigns, assigns.tooltip)

    ~H"""
    <Tooltip.tooltip :let={tip} id={@tooltip_id} text={@tooltip}>
      <button
        type={@button_type}
        form={@form}
        disabled={@native_disabled}
        aria-describedby={describedby(tip, @rest)}
        class={action_classes(@variant, @size, @class)}
        {@control_rest}
      >
        <.leading_icon :if={@icon} name={@icon} size={@size} />
        {render_slot(@inner_block)}
      </button>
    </Tooltip.tooltip>
    """
  end

  @doc """
  Renders a link with the look of `action_button/1`.

  Takes exactly one of `navigate`, `patch` or `href`, as `Phoenix.Component.link/1`
  does, and the same `variant`, `size` and `icon` options as `action_button/1`.
  """
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :any, default: nil
  attr :replace, :boolean, default: false
  attr :method, :string, default: "get"
  attr :variant, :atom, default: :primary, values: @variants
  attr :size, :atom, default: :md, values: @sizes
  attr :icon, :string, default: nil, doc: "A leading `hero-…` icon name"
  attr :class, :any, default: ""

  attr :rest, :global, include: ~w(download hreflang referrerpolicy rel target type csrf_token)

  slot :inner_block, required: true

  @spec action_link(map()) :: Phoenix.LiveView.Rendered.t()
  def action_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      replace={@replace}
      method={@method}
      class={action_classes(@variant, @size, @class)}
      {@rest}
    >
      <.leading_icon :if={@icon} name={@icon} size={@size} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Renders a loading button with spinner.

  ## Options
    * `:loading` - Whether to show loading state
    * `:loading_text` - Text to show when loading
    * `:variant`, `:size`, `:icon` - As for `action_button/1`; the icon gives way
      to the spinner while loading
  """
  attr :loading, :boolean, default: false
  attr :loading_text, :string, default: nil
  attr :variant, :atom, default: :primary, values: @variants
  attr :size, :atom, default: :md, values: @sizes
  attr :icon, :string, default: nil, doc: "A leading `hero-…` icon name"
  attr :type, :string, default: "button"
  attr :form, :string, default: nil
  attr :class, :any, default: ""
  attr :disabled, :boolean, default: false
  attr :tooltip, :any, default: nil, doc: "As for `action_button/1`; ignored while loading"
  attr :rest, :global

  slot :inner_block, required: true

  @spec loading_button(map()) :: Phoenix.LiveView.Rendered.t()
  def loading_button(assigns) do
    ~H"""
    <.action_button
      variant={@variant}
      size={@size}
      icon={if @loading, do: nil, else: @icon}
      type={@type}
      form={@form}
      disabled={@loading or @disabled}
      tooltip={if @loading, do: nil, else: @tooltip}
      class={@class}
      {@rest}
    >
      <%= if @loading do %>
        <Feedback.spinner />
        <span>{@loading_text || dgettext("common", "Processing...")}</span>
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </.action_button>
    """
  end

  @doc """
  Renders a square, icon-only button.

  `label` is required: it is the button's accessible name (`aria-label`) and,
  unless `tooltip` is given, the text of its `<.tooltip>`, since there is no
  visible text. On touch screens the hit area extends to at least 44px whatever
  the visual size.

  A `tooltip` different from `label` is linked by `aria-describedby`, so give
  the button an `id` (`CredoChecks.NoNativeTitle` insists).

  For a control that is unavailable but should say why, keep `label` naming
  the action ("Copy link"), put the reason in `tooltip` and pass `disabled`
  or `aria-disabled="true"`. The button then renders `aria-disabled`, so it
  stays focusable and the reason stays reachable, and its `phx-click` is
  dropped so it cannot fire.

  ## Options
    * `:icon` - The `hero-…` icon name
    * `:label` - The accessible name, e.g. "Edit time off"
    * `:tooltip` - The tooltip text, when it should differ from `label`
    * `:variant` - `:neutral` (bordered tile), `:danger` (quiet until hovered,
      then red) or `:warning` (amber tile). Defaults to `:neutral`
    * `:size` - `:sm` (32px) or `:md` (36px). Defaults to `:md`
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tooltip, :any, default: nil
  attr :variant, :atom, default: :neutral, values: @icon_variants
  attr :size, :atom, default: :md, values: @icon_sizes
  attr :type, :string, default: "button"
  attr :disabled, :boolean, default: false
  attr :class, :any, default: ""
  attr :rest, :global

  @spec icon_button(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_button(assigns) do
    assigns = assign_availability(assigns, assigns.tooltip)

    ~H"""
    <Tooltip.tooltip :let={tip} id={@tooltip_id} text={@tooltip || @label}>
      <button
        type={@button_type}
        disabled={@native_disabled}
        aria-label={@label}
        aria-describedby={describedby(tip, @rest)}
        class={["icon-button", "icon-button--#{@variant}", "icon-button--#{@size}", @class]}
        {@control_rest}
      >
        <Icons.icon name={@icon} class={icon_size_class(@size)} />
      </button>
    </Tooltip.tooltip>
    """
  end

  # Works out how a button renders from `disabled` and `tooltip`:
  #
  #   * a tooltip on an unavailable button is its reason, so the button uses
  #     `aria-disabled` instead of `disabled` to stay focusable, and drops the
  #     attributes that would make it fire;
  #   * `aria-disabled` passed by a caller with a tooltip is treated the same
  #     way; without one the caller owns the event, which may be the server's
  #     own explanation rather than the action (`finish_locked`);
  #   * the tooltip bubble gets an id only when something links to it.
  defp assign_availability(assigns, tooltip) do
    rest = assigns.rest
    id = Map.get(rest, :id)
    aria_disabled? = aria_disabled?(assigns, rest, tooltip)

    control_rest =
      rest
      |> Map.delete(:"aria-describedby")
      |> drop_actions(aria_disabled?)
      |> then(&if(aria_disabled?, do: Map.put(&1, :"aria-disabled", "true"), else: &1))

    assign(assigns,
      tooltip_id: if(present?(tooltip) and id, do: "#{id}-tip"),
      button_type: if(aria_disabled?, do: "button", else: assigns.type),
      native_disabled: assigns.disabled and not aria_disabled?,
      control_rest: control_rest
    )
  end

  defp aria_disabled?(%{disabled: disabled}, rest, tooltip) do
    present?(tooltip) and (disabled or rest[:"aria-disabled"] in [true, "true"])
  end

  defp drop_actions(rest, false), do: rest
  defp drop_actions(rest, true), do: Map.drop(rest, [:"phx-click", :"phx-submit"])

  defp present?(text), do: is_binary(text) and text != ""

  # The tooltip's id, followed by any description the caller passed.
  defp describedby(tip, rest) do
    ids = Enum.reject([tip, Map.get(rest, :"aria-describedby")], &(&1 in [nil, false, ""]))

    if ids != [], do: Enum.join(ids, " ")
  end

  attr :name, :string, required: true
  attr :size, :atom, required: true

  defp leading_icon(assigns) do
    ~H"""
    <Icons.icon name={@name} class={"shrink-0 " <> icon_size_class(@size)} />
    """
  end

  @doc """
  The classes of an action button of the given variant and size, for an
  element that cannot be one of the components above: a `<label>` wrapping a
  file input. Add `aria-disabled="true"` to such an element when it is inert.
  """
  @spec button_classes(atom(), atom()) :: [String.t() | nil]
  def button_classes(variant, size \\ :md) when variant in @variants and size in @sizes do
    ["action-button", variant_class(variant), size_class(size)]
  end

  defp action_classes(variant, size, extra), do: button_classes(variant, size) ++ [extra]

  defp variant_class(:danger_soft), do: "action-button--danger-soft"
  defp variant_class(:on_dark), do: "action-button--on-dark"
  defp variant_class(variant), do: "action-button--#{variant}"

  # :md is the base `.action-button` size, so it needs no modifier class.
  defp size_class(:md), do: nil
  defp size_class(size), do: "action-button--#{size}"

  defp icon_size_class(:sm), do: "w-4 h-4"
  defp icon_size_class(size) when size in [:md, :lg], do: "w-5 h-5"
end
