defmodule TymeslotWeb.Themes.Core.Context do
  @moduledoc """
  Encapsulates all theme-related data and provides a clean interface
  for theme operations. This context serves as the single source of
  truth for theme state within a LiveView session.
  """

  alias Phoenix.Component
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.Registry

  require Logger

  @type layout :: :default | :column

  @type t :: %__MODULE__{
          theme_id: String.t(),
          theme_key: atom(),
          module: module(),
          customizations: map() | nil,
          metadata: map(),
          preview_mode: boolean(),
          layout: layout()
        }

  defstruct theme_id: nil,
            theme_key: nil,
            module: nil,
            customizations: nil,
            metadata: %{},
            preview_mode: false,
            layout: :default

  @doc """
  Returns the list of allowed layout values for embed snippets and URL params.

  This is the authoritative list for the dashboard helpers — it drives input
  validation and snippet emission. The server-side resolver (`apply_layout/2`)
  only recognises `"column"` as a non-default layout; every other value
  (including `"default"`, an absent param, and `?embed=1` with no layout)
  leaves the struct's zero value (`:default`) unchanged.
  """
  @spec valid_layouts() :: [String.t()]
  def valid_layouts, do: ~w(default column)

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
        metadata: extract_metadata(theme),
        preview_mode: Keyword.get(options, :preview, false)
      }
    else
      error ->
        Logger.warning("Failed to load theme context",
          theme_id: theme_id,
          reason: inspect(error)
        )

        nil
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

    preview_mode = PreviewMode.claimed?(params)

    context = new(theme_id, profile, preview: preview_mode)

    if context do
      context
      |> apply_primary_color(params)
      |> apply_layout(params)
    else
      nil
    end
  end

  # Validate hex color format to prevent CSS injection.
  defp apply_primary_color(context, params) do
    with primary_color when is_binary(primary_color) <- params["primary-color"],
         true <- Regex.match?(~r/^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/, primary_color) do
      customizations = Map.put(context.customizations || %{}, "primary_color", primary_color)
      %{context | customizations: customizations}
    else
      _invalid -> context
    end
  end

  # Layout is opt-in via an explicit `?layout=column` param. "column" forces
  # the wide-canvas layout; every other value (including "default", an absent
  # param, or `?embed=1` with no layout) keeps the struct's zero value
  # `:default`.
  #
  # Back-compat is the reason `?embed=1` does NOT imply column. Snippets
  # deployed before the column layout shipped carry no `data-layout`, so
  # embed.js generates their iframe URL with `?embed=1` but no `?layout=`.
  # Defaulting those to column would silently flip every already-embedded
  # booking page to the full-bleed wide layout on upgrade. Only newly
  # generated snippets — which emit `data-layout="column"`, producing
  # `?layout=column` — opt into the wide canvas.
  defp apply_layout(context, %{"layout" => "column"}), do: %{context | layout: :column}

  defp apply_layout(context, _params), do: context

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
      theme_preview: context.preview_mode,
      embed_layout: context.layout
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
      result -> result
    end
  end

  defp load_customizations(theme_id, nil), do: ThemeCustomizations.get_defaults(theme_id)

  defp load_customizations(theme_id, profile) do
    case ThemeCustomizations.get_for_user(profile.user_id, theme_id) do
      nil -> ThemeCustomizations.get_defaults(theme_id)
      customization -> ThemeCustomizations.to_map(customization)
    end
  end

  defp extract_metadata(theme) do
    Map.take(theme, [:name, :description, :css_file])
  end
end
