defmodule TymeslotWeb.Themes.Core.Context do
  @moduledoc """
  Encapsulates all theme-related data and provides a clean interface
  for theme operations. This context serves as the single source of
  truth for theme state within a LiveView session.
  """

  alias Phoenix.Component
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Utils.Colour
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.Registry

  require Logger

  @type layout :: :default | :column

  @type t :: %__MODULE__{
          theme_id: String.t(),
          theme_key: atom(),
          module: module(),
          preview_mode: boolean(),
          layout: layout(),
          overrides: %{optional(:primary_color) => String.t()}
        }

  defstruct theme_id: nil,
            theme_key: nil,
            module: nil,
            preview_mode: false,
            layout: :default,
            overrides: %{}

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
  Creates a new theme context from a theme ID and options (`preview:`).
  """
  @spec new(String.t(), keyword()) :: t() | nil
  def new(theme_id, options \\ []) do
    with {:ok, theme} <- Registry.get_theme_by_id(theme_id),
         {:ok, module} <- ensure_module_loaded(theme.module) do
      %__MODULE__{
        theme_id: theme_id,
        theme_key: theme.key,
        module: module,
        preview_mode: Keyword.get(options, :preview, false)
      }
    else
      error ->
        Logger.warning("Failed to load theme context",
          theme_id: theme_id,
          reason: LogFormat.reason(error)
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
      Registry.requested_theme_id(params) || organiser_theme_id(profile) ||
        Registry.default_theme_id()

    preview_mode = PreviewMode.claimed?(params)

    case new(theme_id, preview: preview_mode) do
      %__MODULE__{} = context -> context |> apply_overrides(params) |> apply_layout(params)
      nil -> nil
    end
  end

  defp organiser_theme_id(%{booking_theme: theme_id}) when is_binary(theme_id) do
    if Registry.valid_theme_id?(theme_id), do: theme_id
  end

  defp organiser_theme_id(_no_profile), do: nil

  # A per-embed accent colour (`data-primary-color`, sent by embed.js as
  # `?primary-color=`). It overrides the saved palette for this page view only:
  # nothing is persisted, and the theme's spec recomputes the contrast pairs
  # for it.
  defp apply_overrides(context, %{"primary-color" => value}) when is_binary(value) do
    case Colour.cast_hex(value) do
      {:ok, hex} -> %{context | overrides: %{primary_color: hex}}
      :error -> context
    end
  end

  defp apply_overrides(context, _params), do: context

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
  Converts the context to assigns for LiveView consumption.
  """
  @spec to_assigns(t()) :: map()
  def to_assigns(%__MODULE__{} = context) do
    %{
      theme_context: context,
      theme_id: context.theme_id,
      theme_key: context.theme_key,
      theme_module: context.module,
      theme_preview: context.preview_mode,
      embed_layout: context.layout,
      theme_overrides: context.overrides
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
end
