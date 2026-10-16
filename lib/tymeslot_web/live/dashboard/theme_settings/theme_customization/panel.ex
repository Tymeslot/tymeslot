defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel do
  @moduledoc """
  A dashboard panel for one option group, drawn inside
  `ThemeCustomizationComponent` for every group the theme's spec lists.

  A panel is a function component module that `use`s this one. It writes only
  through the `theme:set_option` event (`phx-value-option` the group's key,
  `phx-value-field`, `phx-value-choice`, targeted at `@myself`), which
  `ThemeCustomizations.apply_option/4` handles through the group's module.

  What a panel shows between writes (an open tab, an expanded disclosure) is
  its UI state: a map the component keeps per group and spreads into the
  panel's assigns. Any other `theme:*` event carrying `phx-value-option` with
  the group's key is a UI event, handed to `handle_ui/5`. `use` supplies a
  default for each callback but `render/1`: no state, no UI events, and a
  generic `:option_changed` telemetry event.

  `Panels.for_group/2` says which panel a group gets.
  """

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @typedoc "A panel's UI state, spread into its assigns."
  @type ui :: %{optional(atom()) => term()}

  @doc """
  Renders the panel. Receives `group` (its descriptor), `customization`,
  `uploads`, `myself` and the panel's UI state as assigns.
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  The UI state for `customization`: on load `ui` is `%{}`; after a save of
  one of this group's options it is the state before the save.
  """
  @callback ui(OptionGroup.group(), ThemeCustomizationSchema.t(), ui()) :: ui()

  @doc """
  A UI event: new UI state, a write to make as `theme:set_option` would
  (`{:set, field, value}`), or `:ignore`.
  """
  @callback handle_ui(
              event :: String.t(),
              params :: map(),
              OptionGroup.group(),
              ui(),
              ThemeCustomizationSchema.t()
            ) :: {:ui, ui()} | {:set, field :: String.t(), value :: String.t()} | :ignore

  @doc "The telemetry event name, rate-limit label and metadata of a write."
  @callback telemetry(OptionGroup.group(), field :: String.t(), value :: String.t()) ::
              {atom(), String.t(), map()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def ui(_group, _customization, ui), do: ui

      @impl unquote(__MODULE__)
      def handle_ui(_event, _params, _group, _ui, _customization), do: :ignore

      @impl unquote(__MODULE__)
      def telemetry(group, field, value),
        do: {:option_changed, Atom.to_string(group.key), %{field: field, value: value}}

      defoverridable ui: 3, handle_ui: 5, telemetry: 3
    end
  end
end
