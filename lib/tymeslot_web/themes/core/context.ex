defmodule TymeslotWeb.Themes.Core.Context do
  @moduledoc """
  Encapsulates all theme-related data and provides a clean interface
  for theme operations. This context serves as the single source of
  truth for theme state within a LiveView session.
  """

  alias Phoenix.Component
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Themes.Core.Registry

  @type t :: %__MODULE__{
          theme_id: String.t(),
          theme_key: atom(),
          module: module(),
          customizations: map() | nil,
          capabilities: map(),
          metadata: map(),
          preview_mode: boolean()
        }

  defstruct theme_id: nil,
            theme_key: nil,
            module: nil,
            customizations: nil,
            capabilities: %{},
            metadata: %{},
            preview_mode: false

  @doc """
  Creates a new theme context from a theme ID and optional profile.
  """
  @spec new(String.t(), map() | nil, keyword()) :: t() | nil
  def new(theme_id, profile \\ nil, options \\ []) do
    with {:ok, theme} <- Registry.get_theme_by_id(theme_id),
         {:ok, module} <- ensure_module_loaded(theme.module) do
      %__MODULE__{
        theme_id: theme_id,
        theme_key: theme.key,
        module: module,
        customizations: load_customizations(theme_id, profile),
        capabilities: extract_capabilities(theme),
        metadata: extract_metadata(theme),
        preview_mode: Keyword.get(options, :preview, false)
      }
    else
      _ -> nil
    end
  end

  @doc """
  Creates a theme context from URL params, handling preview mode.
  """
  @spec from_params(map(), map() | nil) :: t() | nil
  def from_params(params, profile \\ nil) do
    theme_id =
      params["theme"] || params["theme_id"] ||
        (profile && profile.booking_theme) ||
        Registry.default_theme_id()

    preview_mode = Map.has_key?(params, "theme")

    new(theme_id, profile, preview: preview_mode)
  end

  @doc """
  Updates the context with new customizations.
  """
  @spec update_customizations(t(), map()) :: t()
  def update_customizations(%__MODULE__{} = context, customizations) do
    %{context | customizations: customizations}
  end

  @doc """
  Checks if a theme capability is enabled.
  """
  @spec supports?(t(), atom()) :: boolean()
  def supports?(%__MODULE__{capabilities: capabilities}, capability) do
    Map.get(capabilities, capability, false)
  end

  @doc """
  Gets the CSS file path for the theme.
  """
  @spec css_file(t()) :: String.t() | nil
  def css_file(%__MODULE__{metadata: metadata}) do
    Map.get(metadata, :css_file)
  end

  @doc """
  Gets the theme name for display.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{metadata: metadata}) do
    Map.get(metadata, :name, "Unknown Theme")
  end

  @doc """
  Converts the context to assigns for LiveView consumption.
  """
  @spec to_assigns(t()) :: map()
  def to_assigns(%__MODULE__{} = context) do
    %{
      theme_context: context,
      theme_id: context.theme_id,
      theme_key: context.theme_key,
      theme_module: context.module,
      theme_customization: context.customizations,
      theme_preview: context.preview_mode
    }
  end

  @doc """
  Merges theme context data into existing socket assigns.
  """
  @spec assign_to_socket(Phoenix.LiveView.Socket.t(), t()) :: Phoenix.LiveView.Socket.t()
  def assign_to_socket(socket, %__MODULE__{} = context) do
    assigns = to_assigns(context)

    Enum.reduce(assigns, socket, fn {key, value}, acc ->
      Component.assign(acc, key, value)
    end)
  end

  # Private functions

  defp ensure_module_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      error -> error
    end
  end

  defp load_customizations(theme_id, nil), do: ThemeCustomizations.get_defaults(theme_id)

  defp load_customizations(theme_id, profile) do
    case ThemeCustomizations.get_for_user(profile.user_id, theme_id) do
      nil -> ThemeCustomizations.get_defaults(theme_id)
      customization -> ThemeCustomizations.to_map(customization)
    end
  end

  defp extract_capabilities(theme) do
    theme.features
  end

  defp extract_metadata(theme) do
    Map.take(theme, [:name, :description, :css_file, :preview_image])
  end
end
