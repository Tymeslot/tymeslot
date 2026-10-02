defmodule TymeslotWeb.Components.CoreComponents do
  @moduledoc """
  Core UI components used throughout the application.

  Each component lives, with its markup, its documentation and its
  `attr`/`slot` declarations, in a submodule grouped by kind (`Buttons`,
  `Containers`, `Feedback`, `Modal`, …). `use TymeslotWeb.Components.CoreComponents`
  (which `use TymeslotWeb, :html` does for every template) imports the shared
  ones, listed below, so `<.pill>` calls `Feedback.pill/1` directly and is
  checked at compile time against its own declarations. Outside an import,
  call the submodule: `<Feedback.pill>`.

  There is deliberately no delegating facade. One would have to restate every
  declaration (and a restatement that fell behind its component silently
  rejected the difference) or read them from the submodules at compile time,
  which makes this module a compile-time dependant of every component.

  Adding a shared component: write it in the submodule it belongs to (or a new
  one), then add its name to `@components`.

  `use` takes `only: [name: 1, …]` to import a subset. `button_classes/1,2`,
  the classes of an action button for an element that cannot be one, comes
  along with the buttons.
  """

  # Submodules are named by atom, never by alias: an alias reference would
  # make this module depend on every component, and every template that
  # `use`s it a compile-time dependant of all of them. The full names are
  # built once, here, at compile time.
  @shared [
    {:Brand, [:logo]},
    {:Layout, [:page_layout, :footer]},
    {:Buttons,
     [
       :action_button,
       :action_link,
       :loading_button,
       :icon_button,
       button_classes: 1,
       button_classes: 2
     ]},
    {:Containers,
     [
       :glass_morphism_card,
       :detail_card,
       :section_header,
       :detail_line,
       :info_box,
       :card,
       :subsection_header
     ]},
    {:Forms, [:input, :form_wrapper, :password_requirements]},
    {:SettingRow, [:setting_row]},
    {:Feedback, [:spinner, :empty_state, :loading_card, :pill]},
    {:Navigation, [:detail_row, :tab_bar, :segmented_control]},
    {:Dropdown, [:dropdown, :dropdown_item, :dropdown_divider]},
    {:Flash, [:flash, :flash_group]},
    {:Modal, [:modal, :confirm_modal]},
    {:Icons, [:icon]}
  ]

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  @components for {name, functions} <- @shared, do: {Module.concat(__MODULE__, name), functions}

  @doc """
  Each shared function component's name and the submodule that defines it.
  Helpers that are not components (`button_classes/1,2`) are imported too but
  not listed here.
  """
  @spec components() :: %{atom() => module()}
  def components do
    Map.new(
      for {module, names} <- @components,
          name when is_atom(name) <- names,
          do: {name, module}
    )
  end

  @doc false
  defmacro __using__(opts) do
    wanted = Keyword.get(opts, :only)

    for {module, names} <- @components,
        imports =
          for(name <- names, fun = function(name), wanted == nil or fun in wanted, do: fun),
        imports != [] do
      quote do
        import unquote(module), only: unquote(imports)
      end
    end
  end

  defp function({name, arity}), do: {name, arity}
  defp function(name), do: {name, 1}
end
