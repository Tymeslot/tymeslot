defmodule TymeslotWeb.Components.CoreComponents.Brand do
  @moduledoc "Brand-related components (logos, marks) extracted from CoreComponents."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders the Tymeslot logo.

  ## Attributes
    * `mode` - Either :full (logo + text) or :icon (logo only). Defaults to :full.
    * `class` - Additional CSS classes for the container.
    * `img_class` - Additional CSS classes for the image element.
  """
  attr :mode, :atom, default: :full, values: [:full, :icon]
  attr :class, :string, default: nil
  attr :img_class, :string, default: "h-10"

  @spec logo(map()) :: Phoenix.LiveView.Rendered.t()
  def logo(assigns) do
    ~H"""
    <div class={["flex items-center", @class]}>
      <%= if @mode == :full do %>
        <img
          src="/images/brand/logo-with-text.svg"
          alt="Tymeslot"
          width="620"
          height="200"
          class={[@img_class, "w-auto"]}
        />
      <% else %>
        <img
          src="/images/brand/logo.svg"
          alt={dgettext("common", "Tymeslot logo")}
          width="200"
          height="200"
          class={[@img_class, "w-auto"]}
        />
      <% end %>
    </div>
    """
  end
end
