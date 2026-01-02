defmodule Tymeslot.DatabaseSchemas.ThemeCustomizationSchema do
  @moduledoc """
  Schema for user theme customizations including color schemes and backgrounds.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias TymeslotWeb.Themes.Core.Registry

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          theme_id: String.t() | nil,
          color_scheme: String.t(),
          background_type: String.t(),
          background_value: String.t() | nil,
          background_image_path: String.t() | nil,
          background_video_path: String.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @valid_color_schemes ~w[default turquoise purple sunset ocean forest rose monochrome]
  @valid_background_types ~w[gradient color image video]

  schema "theme_customizations" do
    field(:theme_id, :string)
    field(:color_scheme, :string, default: "default")
    field(:background_type, :string, default: "gradient")
    field(:background_value, :string)
    field(:background_image_path, :string)
    field(:background_video_path, :string)

    belongs_to(:profile, ProfileSchema, foreign_key: :profile_id)

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(theme_customization, attrs) do
    theme_customization
    |> cast(attrs, [
      :profile_id,
      :theme_id,
      :color_scheme,
      :background_type,
      :background_value,
      :background_image_path,
      :background_video_path
    ])
    |> validate_required([:profile_id, :theme_id, :color_scheme, :background_type])
    |> validate_theme_id()
    |> validate_inclusion(:color_scheme, @valid_color_schemes)
    |> validate_inclusion(:background_type, @valid_background_types)
    |> validate_background_value()
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:profile_id, :theme_id])
  end

  @doc """
  Returns all valid color schemes.
  """
  @spec valid_color_schemes() :: [String.t()]
  def valid_color_schemes, do: @valid_color_schemes

  @doc """
  Returns all valid background types.
  """
  @spec valid_background_types() :: [String.t()]
  def valid_background_types, do: @valid_background_types

  @doc """
  Color scheme definitions with their CSS variables.
  """
  @spec color_scheme_definitions() :: map()
  def color_scheme_definitions do
    %{
      "default" => %{
        name: "Default Turquoise",
        colors: %{
          primary: "#06b6d4",
          primary_hover: "#0891b2",
          secondary: "#14b8a6",
          accent: "#10b981",
          background: "#0f172a",
          surface: "rgba(30, 41, 59, 0.5)",
          text: "#e2e8f0",
          text_secondary: "#94a3b8"
        }
      },
      "turquoise" => %{
        name: "Arctic Blue",
        colors: %{
          primary: "#0284c7",
          primary_hover: "#0369a1",
          secondary: "#0ea5e9",
          accent: "#38bdf8",
          background: "#0c1426",
          surface: "rgba(15, 23, 42, 0.6)",
          text: "#e0f2fe",
          text_secondary: "#7dd3fc"
        }
      },
      "purple" => %{
        name: "Purple Dream",
        colors: %{
          primary: "#8b5cf6",
          primary_hover: "#7c3aed",
          secondary: "#a78bfa",
          accent: "#c084fc",
          background: "#1e1b4b",
          surface: "rgba(46, 38, 84, 0.5)",
          text: "#ede9fe",
          text_secondary: "#c4b5fd"
        }
      },
      "sunset" => %{
        name: "Sunset Glow",
        colors: %{
          primary: "#f97316",
          primary_hover: "#ea580c",
          secondary: "#fb923c",
          accent: "#fbbf24",
          background: "#431407",
          surface: "rgba(92, 45, 10, 0.5)",
          text: "#fef3c7",
          text_secondary: "#fed7aa"
        }
      },
      "ocean" => %{
        name: "Ocean Breeze",
        colors: %{
          primary: "#0ea5e9",
          primary_hover: "#0284c7",
          secondary: "#38bdf8",
          accent: "#7dd3fc",
          background: "#082f49",
          surface: "rgba(12, 74, 110, 0.5)",
          text: "#e0f2fe",
          text_secondary: "#bae6fd"
        }
      },
      "forest" => %{
        name: "Forest Green",
        colors: %{
          primary: "#10b981",
          primary_hover: "#059669",
          secondary: "#34d399",
          accent: "#6ee7b7",
          background: "#052e16",
          surface: "rgba(20, 83, 45, 0.5)",
          text: "#d1fae5",
          text_secondary: "#a7f3d0"
        }
      },
      "rose" => %{
        name: "Rose Gold",
        colors: %{
          primary: "#f43f5e",
          primary_hover: "#e11d48",
          secondary: "#fb7185",
          accent: "#fda4af",
          background: "#4c0519",
          surface: "rgba(136, 19, 55, 0.5)",
          text: "#ffe4e6",
          text_secondary: "#fecdd3"
        }
      },
      "monochrome" => %{
        name: "Monochrome",
        colors: %{
          primary: "#6b7280",
          primary_hover: "#4b5563",
          secondary: "#9ca3af",
          accent: "#d1d5db",
          background: "#111827",
          surface: "rgba(31, 41, 55, 0.5)",
          text: "#f3f4f6",
          text_secondary: "#d1d5db"
        }
      }
    }
  end

  @doc """
  Gradient background definitions (alias for gradient_presets).
  """
  @spec gradient_definitions() :: %{
          optional(String.t()) => %{name: String.t(), value: String.t()}
        }
  def gradient_definitions, do: gradient_presets()

  @doc """
  Gradient background presets.
  """
  @spec gradient_presets() :: map()
  @spec gradient_presets() :: %{optional(String.t()) => %{name: String.t(), value: String.t()}}
  def gradient_presets do
    %{
      "gradient_1" => %{
        name: "Aurora",
        value: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
      },
      "gradient_2" => %{
        name: "Ocean",
        value: "linear-gradient(135deg, #2E3192 0%, #1BFFFF 100%)"
      },
      "gradient_3" => %{
        name: "Sunset",
        value: "linear-gradient(135deg, #FC466B 0%, #3F5EFB 100%)"
      },
      "gradient_4" => %{
        name: "Forest",
        value: "linear-gradient(135deg, #11998e 0%, #38ef7d 100%)"
      },
      "gradient_5" => %{
        name: "Berry",
        value: "linear-gradient(135deg, #4e54c8 0%, #8f94fb 100%)"
      },
      "gradient_6" => %{
        name: "Midnight",
        value: "linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%)"
      },
      "gradient_7" => %{
        name: "Coral",
        value: "linear-gradient(135deg, #fa709a 0%, #fee140 100%)"
      },
      "gradient_8" => %{
        name: "Northern Lights",
        value: "linear-gradient(135deg, #43cea2 0%, #185a9d 100%)"
      }
    }
  end

  @doc """
  Video background presets for themes.
  """
  @spec video_presets() :: map()
  def video_presets do
    %{
      "preset:rhythm-default" => %{
        name: "Rhythm Default",
        file: "rhythm-background-desktop.webm",
        thumbnail: "rhythm-background-thumbnail.jpg",
        description: "Default Rhythm theme video"
      },
      "preset:blue-wave" => %{
        name: "Blue Wave",
        file: "blue-wave-desktop.mp4",
        thumbnail: "blue-wave-thumbnail.jpg",
        description: "Flowing blue wave animation"
      },
      "preset:dancing-girl" => %{
        name: "Dancing Girl",
        file: "dancing-girl-desktop.mp4",
        thumbnail: "dancing-girl-thumbnail.jpg",
        description: "Elegant dancing silhouette"
      },
      "preset:leaves" => %{
        name: "Falling Leaves",
        file: "leaves-desktop.mp4",
        thumbnail: "leaves-thumbnail.jpg",
        description: "Peaceful autumn leaves falling"
      },
      "preset:light-green" => %{
        name: "Light Green",
        file: "light-green-desktop.mp4",
        thumbnail: "light-green-thumbnail.jpg",
        description: "Soothing light green abstract"
      },
      "preset:space" => %{
        name: "Space Journey",
        file: "space-desktop.mp4",
        thumbnail: "space-thumbnail.jpg",
        description: "Cosmic space exploration"
      }
    }
  end

  @doc """
  Image background presets for themes.
  """
  @spec image_presets() :: map()
  def image_presets do
    %{
      "preset:artistic-studio" => %{
        name: "Artistic Studio",
        file: "artistic-studio.webp",
        thumbnail: "artistic-studio-thumbnail.webp",
        description: "Creative artistic workspace scene"
      },
      "preset:rustic-farmhouse" => %{
        name: "Rustic Farmhouse",
        file: "rustic-farmhouse.webp",
        thumbnail: "rustic-farmhouse-thumbnail.webp",
        description: "Cozy farmhouse still life with rustic charm"
      },
      "preset:space-satellite" => %{
        name: "Space Satellite",
        file: "space-satellite.webp",
        thumbnail: "space-satellite-thumbnail.webp",
        description: "Modern satellite technology in space"
      },
      "preset:elegant-still-life" => %{
        name: "Elegant Still Life",
        file: "elegant-still-life.webp",
        thumbnail: "elegant-still-life-thumbnail.webp",
        description: "Sophisticated still life composition"
      },
      "preset:ocean-sunset" => %{
        name: "Ocean Sunset",
        file: "ocean-sunset.webp",
        thumbnail: "ocean-sunset-thumbnail.webp",
        description: "Peaceful ocean sunset with surfer silhouette"
      }
    }
  end

  defp validate_background_value(changeset) do
    background_type = get_field(changeset, :background_type)

    case background_type do
      "gradient" -> validate_gradient(changeset)
      "color" -> validate_color(changeset)
      "image" -> validate_image(changeset)
      "video" -> validate_video(changeset)
      _ -> changeset
    end
  end

  defp validate_gradient(changeset) do
    background_value = get_field(changeset, :background_value)

    if background_value && Map.has_key?(gradient_presets(), background_value) do
      changeset
    else
      add_error(changeset, :background_value, "must be a valid gradient preset")
    end
  end

  defp validate_color(changeset) do
    background_value = get_field(changeset, :background_value)

    if background_value && String.match?(background_value, ~r/^#[0-9A-Fa-f]{6}$/) do
      changeset
    else
      add_error(changeset, :background_value, "must be a valid hex color")
    end
  end

  defp validate_image(changeset) do
    background_value = get_field(changeset, :background_value)

    # Preset images don't need an image path
    if background_value && String.starts_with?(background_value, "preset:") do
      changeset
    else
      # Uploaded images require an image path
      if get_field(changeset, :background_image_path) do
        changeset
      else
        add_error(changeset, :background_image_path, "is required for uploaded image background")
      end
    end
  end

  defp validate_video(changeset) do
    background_value = get_field(changeset, :background_value)

    # Preset videos don't need a video path
    if background_value && String.starts_with?(background_value, "preset:") do
      changeset
    else
      # Uploaded videos require a video path
      if get_field(changeset, :background_video_path) do
        changeset
      else
        add_error(changeset, :background_video_path, "is required for uploaded video background")
      end
    end
  end

  defp validate_theme_id(changeset) do
    case get_field(changeset, :theme_id) do
      nil ->
        changeset

      theme_id ->
        if Registry.valid_theme_id?(theme_id) do
          changeset
        else
          add_error(changeset, :theme_id, "is not a valid theme")
        end
    end
  end
end
