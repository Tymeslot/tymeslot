defmodule TymeslotWeb.Components.CoreComponents do
  @moduledoc """
  Core UI components used throughout the application.

  The stable entry point: templates import it (through `use TymeslotWeb,
  :html`) or alias it, while each component lives, with its markup, its
  documentation and its `attr`/`slot` declarations, in a submodule grouped by
  kind. `Facade.expose/2` gives this module a function for each listed
  component carrying those same declarations, so a caller is checked at
  compile time against the component itself and nothing is declared twice.

  Adding a shared component: write it in the submodule it belongs to (or a new
  one), then add its name to that submodule's `expose` line below.
  """
  use Phoenix.Component

  require Phoenix.Component.Declarative
  require TymeslotWeb.Components.CoreComponents.Facade

  alias TymeslotWeb.Components.CoreComponents.{
    Brand,
    Buttons,
    Containers,
    Dropdown,
    Facade,
    Feedback,
    Flash,
    Forms,
    Icons,
    Layout,
    Modal,
    Navigation
  }

  Module.register_attribute(__MODULE__, :exposed_component, accumulate: true)

  Facade.expose(Brand, [:logo])
  Facade.expose(Layout, [:page_layout, :footer])
  Facade.expose(Buttons, [:action_button, :action_link, :loading_button, :icon_button])

  Facade.expose(Containers, [
    :glass_morphism_card,
    :detail_card,
    :section_header,
    :detail_line,
    :info_box
  ])

  Facade.expose(Forms, [:input, :form_wrapper, :password_requirements])
  Facade.expose(Feedback, [:spinner, :empty_state, :loading_card, :pill])
  Facade.expose(Navigation, [:detail_row, :tabs, :tab_bar])
  Facade.expose(Dropdown, [:dropdown, :dropdown_item])
  Facade.expose(Flash, [:flash, :flash_group])
  Facade.expose(Modal, [:modal, :confirm_modal])
  Facade.expose(Icons, [:icon])

  @doc false
  @spec __exposed__() :: %{atom() => module()}
  def __exposed__, do: Map.new(@exposed_component)

  @doc "Thin horizontal separator inside a dropdown panel. See `Dropdown.dropdown_divider/1`."
  @spec dropdown_divider(map()) :: Phoenix.LiveView.Rendered.t()
  defdelegate dropdown_divider(assigns), to: Dropdown

  @doc """
  The classes of an action button, for an element that cannot be one: a
  `<label>` wrapping a file input. See `Buttons.classes/2`.
  """
  @spec button_classes(atom(), atom()) :: [String.t() | nil]
  defdelegate button_classes(variant, size \\ :md), to: Buttons, as: :classes
end
