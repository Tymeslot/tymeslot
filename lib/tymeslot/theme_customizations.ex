defmodule Tymeslot.ThemeCustomizations do
  @moduledoc """
  The ThemeCustomizations context for managing user theme customizations.
  Main orchestrator that coordinates between functional submodules and handles I/O operations.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  # Functional submodules
  alias __MODULE__.{
    Backgrounds,
    Capability,
    Css,
    DataTransform,
    Defaults,
    FileLifecycle,
    Presets,
    Storage,
    Validation
  }

  @type profile_id :: pos_integer()

  @typedoc """
  Whose customizations: a profile id for its own page at `/<username>`, or
  `{profile_id, page_id}` for one of its booking pages.
  """
  @type scope :: profile_id() | {profile_id(), pos_integer()}
  @type theme_id :: String.t()
  @type user_id :: pos_integer()
  @type customization_input :: ThemeCustomizationSchema.t() | map() | nil
  @type upload_attrs :: %{path: String.t(), filename: String.t()}
  @type persistence_result :: {:ok, ThemeCustomizationSchema.t()} | {:error, Changeset.t()}

  @doc """
  Gets a theme customization by scope (see `t:scope/0`) and theme ID.
  """
  @spec get_by_profile_and_theme(scope(), theme_id()) :: ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme({profile_id, page_id}, theme_id),
    do: ThemeCustomizationQueries.get_by_page_and_theme(profile_id, page_id, theme_id)

  def get_by_profile_and_theme(profile_id, theme_id),
    do: ThemeCustomizationQueries.get_by_profile_and_theme(profile_id, theme_id)

  @doc """
  The scope a profile's start page reads its colours from: the booking page it
  was resolved through (`Tymeslot.BookingPages.apply_to_profile/2`), or the
  profile's own.
  """
  @spec scope_for(map()) :: scope()
  def scope_for(%{id: profile_id, booking_page: %{id: page_id}}), do: {profile_id, page_id}
  def scope_for(%{id: profile_id}), do: profile_id

  @doc """
  Returns a random video-background preset key (e.g. `"preset:blue-wave"`).

  Used to seed a fresh account with a moving background so its booking page —
  and the onboarding preview of it — has life out of the box.
  """
  @spec random_video_preset() :: String.t()
  def random_video_preset do
    Presets.get_video_presets()
    |> Map.keys()
    |> Enum.random()
  end

  @doc """
  Creates or updates a theme customization for a profile and theme.
  """
  @spec upsert_theme_customization(scope(), theme_id(), map()) ::
          persistence_result()
  def upsert_theme_customization(scope, theme_id, attrs) do
    case get_by_profile_and_theme(scope, theme_id) do
      nil ->
        # Create with required defaults if not present
        create_attrs =
          Map.merge(
            %{
              "color_scheme" => "default",
              "background_type" => "gradient",
              "background_value" => "gradient_1"
            },
            attrs
          )

        create_theme_customization(scope, theme_id, create_attrs)

      customization ->
        # Update only the provided fields
        update_theme_customization(customization, attrs)
    end
  end

  @doc """
  Creates a theme customization for a profile and theme.
  """
  @spec create_theme_customization(scope(), theme_id(), map()) :: persistence_result()
  def create_theme_customization(scope, theme_id, attrs) do
    attrs =
      attrs
      |> Map.merge(scope_attrs(scope))
      |> Map.put("theme_id", theme_id)

    # Create the customization with race condition handling
    case ThemeCustomizationQueries.create(attrs) do
      {:ok, result} ->
        {:ok, result}

      {:error, changeset} ->
        # If we hit a unique constraint, it means another request created it concurrently.
        # In this case, we should update the existing record instead.
        if has_unique_constraint_error?(changeset) do
          case get_by_profile_and_theme(scope, theme_id) do
            # Should not happen if constraint violated
            nil -> {:error, changeset}
            customization -> update_theme_customization(customization, attrs)
          end
        else
          {:error, changeset}
        end
    end
  end

  # Either unique index: the profile's own row or a page's.
  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
      field in [:profile_id, :booking_page_id] and Keyword.get(opts, :constraint) == :unique
    end)
  end

  @doc """
  Updates a theme customization using the unified upload system.
  """
  @spec update_theme_customization(ThemeCustomizationSchema.t(), map()) ::
          persistence_result()
  def update_theme_customization(%ThemeCustomizationSchema{} = customization, attrs) do
    # Perform the atomic database update, then cleanup replaced files on success
    case ThemeCustomizationQueries.update(customization, attrs) do
      {:ok, updated} ->
        FileLifecycle.cleanup_replaced_files(customization, attrs)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Removes every theme background file stored for a deleted profile. The rows
  are expected to be gone already; this touches the filesystem only.
  """
  @spec delete_profile_files(profile_id()) :: :ok | {:error, File.posix(), Path.t()}
  def delete_profile_files(profile_id), do: Storage.delete_profile_directory(profile_id)

  @doc """
  Deletes a theme customization.
  """
  @spec delete_theme_customization(ThemeCustomizationSchema.t()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Changeset.t()}
  def delete_theme_customization(%ThemeCustomizationSchema{} = customization) do
    # Delete database record first, then cleanup files on success
    case ThemeCustomizationQueries.delete(customization) do
      {:ok, deleted} ->
        FileLifecycle.cleanup_all_files(customization)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Gets the CSS variables for a color scheme.

  Accepts either a scheme ID (string/atom — looked up in the static preset map)
  or a customisation map. The map form supports the "custom" scheme: when
  `color_scheme == "custom"`, the palette is derived from `custom_palette_seed`
  via `PaletteDerivation.derive_palette/1` instead of preset lookup.
  """
  @spec get_color_scheme_css(String.t() | atom() | map()) :: String.t() | nil
  defdelegate get_color_scheme_css(customization), to: Css

  @doc """
  Gets the CSS for a gradient preset.
  """
  @spec get_gradient_css(String.t() | atom()) :: String.t() | nil
  defdelegate get_gradient_css(gradient_id), to: Css

  @doc """
  Converts a theme customization schema to a map for use in capability-based customization.
  """
  @spec to_map(customization_input()) :: map()
  def to_map(customization) do
    DataTransform.convert_to_map(customization)
  end

  @doc """
  Gets default customization values for a theme based on capabilities.
  """
  @spec get_defaults(theme_id()) :: map()
  def get_defaults(theme_id) do
    Capability.get_capability_defaults(theme_id)
  end

  @doc """
  Generates the full theme CSS variables string (capability-based + legacy fallback)
  for a given theme and customization.
  """
  @spec generate_theme_css(theme_id(), customization_input()) :: String.t()
  def generate_theme_css(theme_id, customization) do
    Css.generate_theme_css(theme_id, to_map(customization))
  end

  # New orchestrator functions for component interface

  @doc """
  Initializes customization data for the component.
  Returns all data needed for component initialization.
  """
  @spec initialize_customization(scope(), theme_id()) :: %{
          customization: ThemeCustomizationSchema.t(),
          original: ThemeCustomizationSchema.t(),
          presets: map()
        }
  def initialize_customization(scope, theme_id) do
    saved = get_by_profile_and_theme(scope, theme_id)
    customization = Defaults.build_initial_customization(profile_id_of(scope), theme_id, saved)

    %{
      customization: customization,
      original: saved || customization,
      presets: Presets.get_all_presets()
    }
  end

  @default_custom_palette_seed "#06b6d4"

  @doc """
  Returns the brand default seed hex used when a user first activates the
  custom-palette mode and has no previously stored seed.
  """
  @spec default_custom_palette_seed() :: String.t()
  def default_custom_palette_seed, do: @default_custom_palette_seed

  @doc """
  Resolves the active colour scheme for a customization, returning the same
  `%{name, colors}` shape used by both presets and palette derivation.

  When `custom_palette_seed` is present on the customization, the palette is
  derived from that seed; otherwise the `color_scheme` field is looked up in
  the provided `presets.color_schemes` map.  Returns `nil` if neither resolves
  to a known scheme.
  """
  @spec resolve_active_scheme(ThemeCustomizationSchema.t() | map(), map()) :: map() | nil
  defdelegate resolve_active_scheme(customization, presets), to: Css

  @doc """
  Applies a color scheme change through the component interface.

  Switching to the "custom" scheme reuses the existing seed if one is already
  stored; otherwise it seeds with the brand turquoise default. Use
  `apply_custom_palette_change/4` directly when the user picks a specific
  custom seed.
  """
  @spec apply_color_scheme_change(
          scope(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t() | atom()
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_color_scheme_change(scope, theme_id, current_customization, "custom") do
    seed = Css.get_seed(current_customization) || @default_custom_palette_seed
    apply_custom_palette_change(scope, theme_id, current_customization, seed)
  end

  def apply_color_scheme_change(scope, theme_id, current_customization, scheme_id) do
    with :ok <- Validation.validate_color_scheme(scheme_id),
         :ok <- validate_theme_capability(theme_id, %{"color_scheme" => scheme_id}),
         new_customization <-
           DataTransform.merge_customization_changes(current_customization, %{
             color_scheme: scheme_id,
             custom_palette_seed: nil
           }),
         save_attrs <- DataTransform.extract_save_attributes(new_customization) do
      scope
      |> upsert_theme_customization(theme_id, save_attrs)
      |> format_persistence_error()
    end
  end

  @doc """
  Switches the customisation to the "custom" colour scheme and persists the seed
  hex used to derive the palette.

  The seed must be a 6-character hex string (with leading `#`); otherwise an
  error is returned without touching the database.
  """
  @spec apply_custom_palette_change(
          scope(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t()
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_custom_palette_change(scope, theme_id, current_customization, seed_hex) do
    with :ok <- Css.validate_seed_hex(seed_hex),
         new_customization <-
           DataTransform.merge_customization_changes(current_customization, %{
             custom_palette_seed: String.downcase(seed_hex)
           }),
         save_attrs <- DataTransform.extract_save_attributes(new_customization) do
      scope
      |> upsert_theme_customization(theme_id, save_attrs)
      |> format_persistence_error()
    end
  end

  @doc """
  Applies a background change through the component interface.
  """
  @spec apply_background_change(
          scope(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t(),
          String.t() | nil
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_background_change(scope, theme_id, current_customization, type, value) do
    presets = Presets.get_all_presets()

    with :ok <- Validation.validate_background_selection(type, value, presets),
         :ok <- validate_theme_capability(theme_id, %{"background_type" => type}),
         new_customization <-
           Backgrounds.apply_background_selection(current_customization, type, value),
         cleanup_files <-
           Backgrounds.determine_cleanup_files(current_customization, new_customization),
         save_attrs <- DataTransform.extract_save_attributes(new_customization),
         {:ok, saved} <-
           scope
           |> upsert_theme_customization(theme_id, save_attrs)
           |> format_persistence_error() do
      Enum.each(cleanup_files, &FileLifecycle.cleanup_old_backgrounds/1)

      {:ok, saved}
    end
  end

  @doc """
  Gets a theme customization for a user, falling back to defaults.
  """
  @spec get_for_user(user_id(), theme_id()) :: ThemeCustomizationSchema.t() | nil
  def get_for_user(user_id, theme_id) do
    profile = get_profile_by_user_id(user_id)

    case profile do
      nil -> nil
      profile -> get_by_profile_and_theme(profile.id, theme_id)
    end
  end

  # Helper to get profile by user_id
  @spec get_profile_by_user_id(user_id()) :: ProfileSchema.t() | nil
  defp get_profile_by_user_id(user_id) do
    ThemeCustomizationQueries.get_profile_by_user_id(user_id)
  end

  @doc """
  Stores a background image for a scope and theme.

  A booking page's upload is stored as `page-<page_id>-<filename>`, so it can
  never overwrite (and later delete) the profile's or another page's file of
  the same name.
  """
  @spec store_background_image(scope(), theme_id(), upload_attrs()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_image(scope, theme_id, upload) do
    Storage.store_background_image(profile_id_of(scope), theme_id, scoped_upload(scope, upload))
  end

  @doc """
  Stores a background video for a scope and theme (see `store_background_image/3`).
  """
  @spec store_background_video(scope(), theme_id(), upload_attrs()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_video(scope, theme_id, upload) do
    Storage.store_background_video(profile_id_of(scope), theme_id, scoped_upload(scope, upload))
  end

  @doc """
  Gives a new booking page copies of its profile's customizations.

  Colour schemes, palettes, gradients, plain colours and preset backgrounds are
  copied. An uploaded image or video background (`background_value == "custom"`)
  is not: the page gets that theme's default background instead, since a file
  shared between two rows would be deleted from under one of them when the
  other replaced it.

  A row the current rules reject (saved before a scheme, preset or theme was
  retired) is left out and logged, so it cannot stop the page being created;
  that theme starts from its defaults on the page. Stops at, and returns, the
  first insert the database refuses.
  """
  @spec copy_to_page(profile_id(), pos_integer()) :: :ok | {:error, Changeset.t()}
  def copy_to_page(profile_id, page_id) do
    profile_id
    |> ThemeCustomizationQueries.list_for_profile_page()
    |> Enum.reduce_while(:ok, fn row, :ok ->
      case create_theme_customization({profile_id, page_id}, row.theme_id, copy_attrs(row)) do
        {:ok, _copy} -> {:cont, :ok}
        {:error, changeset} -> skip_or_stop(changeset, row, page_id)
      end
    end)
  end

  # A constraint error is the database refusing the row; anything else is a
  # validation the row failed before it reached the database.
  defp skip_or_stop(%Changeset{errors: errors} = changeset, row, page_id) do
    if Enum.any?(errors, fn {_field, {_message, opts}} -> Keyword.has_key?(opts, :constraint) end) do
      {:halt, {:error, changeset}}
    else
      Logger.warning("Skipped a colour row the current rules reject while copying it to a page",
        profile_id: row.profile_id,
        page_id: page_id,
        theme_id: row.theme_id,
        reason: LogFormat.reason(errors)
      )

      {:cont, :ok}
    end
  end

  @doc """
  Deletes a booking page's customizations and their uploaded files. Stops at,
  and returns, the first failed delete.
  """
  @spec delete_page_customizations(pos_integer()) :: :ok | {:error, term()}
  def delete_page_customizations(page_id) do
    page_id
    |> ThemeCustomizationQueries.list_by_page()
    |> Enum.reduce_while(:ok, fn row, :ok ->
      case delete_theme_customization(row) do
        {:ok, _deleted} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Private functions

  defp copy_attrs(%{background_value: "custom"} = row) do
    defaults = Defaults.get_theme_defaults(row.theme_id)

    %{
      "color_scheme" => row.color_scheme,
      "custom_palette_seed" => row.custom_palette_seed,
      "background_type" => defaults.background_type,
      "background_value" => defaults.background_value
    }
  end

  defp copy_attrs(row) do
    %{
      "color_scheme" => row.color_scheme,
      "custom_palette_seed" => row.custom_palette_seed,
      "background_type" => row.background_type,
      "background_value" => row.background_value
    }
  end

  defp scope_attrs({profile_id, page_id}),
    do: %{"profile_id" => profile_id, "booking_page_id" => page_id}

  defp scope_attrs(profile_id), do: %{"profile_id" => profile_id}

  defp profile_id_of({profile_id, _page_id}), do: profile_id
  defp profile_id_of(profile_id), do: profile_id

  defp scoped_upload({_profile_id, page_id}, %{filename: filename} = upload),
    do: %{upload | filename: "page-#{page_id}-#{filename}"}

  defp scoped_upload(_profile_id, upload), do: upload

  defp validate_theme_capability(theme_id, attrs) do
    case Capability.validate_customization(theme_id, attrs) do
      {:ok, _attrs} -> :ok
      {:error, reasons} -> {:error, Enum.join(reasons, "; ")}
    end
  end

  # Converts unexpected changeset errors from persistence into a user-safe
  # string. Callers flash the returned message, and `Flash.error/1` guards on
  # binaries — a raw changeset would crash the component.
  @spec format_persistence_error(persistence_result()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  defp format_persistence_error({:ok, _result} = ok), do: ok

  defp format_persistence_error({:error, %Changeset{}}),
    do:
      {:error,
       dgettext(
         "dashboard_appearance",
         "Could not save your theme customization. Please try again."
       )}
end
