defmodule Tymeslot.ThemeCustomizations do
  @moduledoc """
  The ThemeCustomizations context for managing user theme customizations.
  Main orchestrator that coordinates between functional submodules and handles I/O operations.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  # Functional submodules
  alias __MODULE__.{
    Assets,
    DataTransform,
    FileLifecycle,
    Storage
  }

  @type profile_id :: pos_integer()
  @type theme_id :: String.t()
  @type user_id :: pos_integer()
  @type customization_input :: ThemeCustomizationSchema.t() | map() | nil
  @type upload_attrs :: %{path: String.t(), filename: String.t()}
  @type persistence_result :: {:ok, ThemeCustomizationSchema.t()} | {:error, Changeset.t()}

  @doc """
  Gets a theme customization by profile ID and theme ID.
  """
  @spec get_by_profile_and_theme(profile_id(), theme_id()) ::
          ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    ThemeCustomizationQueries.get_by_profile_and_theme(profile_id, theme_id)
  end

  @doc """
  The video-background preset keys a theme offers (e.g. `"preset:blue-wave"`),
  in its background group's order. `[]` for a theme without video backgrounds
  or an unknown id.
  """
  @spec video_preset_keys(theme_id()) :: [String.t()]
  def video_preset_keys(theme_id) do
    with {:ok, spec} <- Catalog.customization_spec(theme_id),
         %{kinds: kinds} = group <- Specs.group(spec, Background),
         true <- :video in kinds do
      group |> Background.presets(:video) |> Enum.map(&elem(&1, 0))
    else
      _no_video -> []
    end
  end

  @doc """
  Picks a preview video per theme from each theme's own list: one preset drawn
  from all of them, given to every theme that lists it, and a random one of its
  own to a theme that does not. Themes with an empty list are left out.

  Used to seed a fresh account with a moving background so its booking page,
  and the onboarding preview of it, has life out of the box.
  """
  @spec preview_videos(%{theme_id() => [String.t()]}) :: %{theme_id() => String.t()}
  def preview_videos(lists) do
    lists = Map.reject(lists, fn {_id, keys} -> keys == [] end)

    case lists |> Map.values() |> List.flatten() |> Enum.uniq() do
      [] ->
        %{}

      all ->
        shared = Enum.random(all)
        Map.new(lists, fn {id, keys} -> {id, preview_video(keys, shared)} end)
    end
  end

  defp preview_video(keys, shared),
    do: if(shared in keys, do: shared, else: Enum.random(keys))

  @doc """
  Whether a theme can show the given kind of background. `false` for an
  unknown theme.
  """
  @spec supports_background?(theme_id(), Spec.background_kind()) :: boolean()
  def supports_background?(theme_id, kind) do
    case Catalog.customization_spec(theme_id) do
      {:ok, spec} -> Specs.supports_background?(spec, kind)
      {:error, :theme_not_found} -> false
    end
  end

  @doc """
  Stores an uploaded file for one of the theme's asset fields and saves it on
  the profile's customisation. See `Tymeslot.ThemeCustomizations.Assets`.
  """
  @spec attach_asset(profile_id(), theme_id(), atom(), upload_attrs()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  defdelegate attach_asset(profile_id, theme_id, field, upload), to: Assets

  @doc """
  The upload columns the theme's customisation spec declares, with the kind of
  each; empty for an unknown theme.
  """
  @spec asset_fields(theme_id()) :: [{atom(), Spec.asset_kind()}]
  def asset_fields(theme_id) do
    case Catalog.customization_spec(theme_id) do
      {:ok, spec} -> spec.asset_fields()
      {:error, :theme_not_found} -> []
    end
  end

  @doc """
  Creates or updates a theme customization for a profile and theme. A new
  row starts from the theme's defaults (the schema changeset reads an empty
  row through `Specs.settings/2`), so `attrs` need only hold what changes.
  """
  @spec upsert_theme_customization(profile_id(), theme_id(), map()) ::
          persistence_result()
  def upsert_theme_customization(profile_id, theme_id, attrs) do
    case get_by_profile_and_theme(profile_id, theme_id) do
      nil -> create_theme_customization(profile_id, theme_id, attrs)
      customization -> update_theme_customization(customization, attrs)
    end
  end

  @doc """
  Creates a theme customization for a profile and theme.
  """
  @spec create_theme_customization(profile_id(), theme_id(), map()) :: persistence_result()
  def create_theme_customization(profile_id, theme_id, attrs) do
    attrs =
      attrs
      |> Map.put("profile_id", profile_id)
      |> Map.put("theme_id", theme_id)

    # Create the customization with race condition handling
    case ThemeCustomizationQueries.create(attrs) do
      {:ok, result} ->
        {:ok, result}

      {:error, changeset} ->
        # If we hit a unique constraint, it means another request created it concurrently.
        # In this case, we should update the existing record instead.
        if has_unique_constraint_error?(changeset) do
          case get_by_profile_and_theme(profile_id, theme_id) do
            # Should not happen if constraint violated
            nil -> {:error, changeset}
            customization -> update_theme_customization(customization, attrs)
          end
        else
          {:error, changeset}
        end
    end
  end

  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
      field == :profile_id and Keyword.get(opts, :constraint) == :unique
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
        FileLifecycle.cleanup_replaced_files(
          Specs.for_theme(customization.theme_id),
          customization,
          updated
        )

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
        FileLifecycle.cleanup_all_files(Specs.for_theme(customization.theme_id), customization)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  The stored settings of a customisation as a string-keyed map, the shape specs
  and tokens work on. Empty for `nil`.
  """
  @spec to_map(customization_input()) :: map()
  def to_map(customization) do
    DataTransform.to_settings(customization)
  end

  @doc """
  The theme's customisation defaults as string-keyed attrs, from its spec.
  """
  @spec get_defaults(theme_id()) :: map()
  def get_defaults(theme_id) do
    Map.new(Specs.for_theme(theme_id).defaults(), fn {key, value} ->
      {Atom.to_string(key), value}
    end)
  end

  @doc """
  An unsaved customisation holding the theme's defaults, for a profile that has
  not customised the theme (or `nil` for a preview without one).
  """
  @spec default_customization(profile_id() | nil, theme_id()) :: ThemeCustomizationSchema.t()
  def default_customization(profile_id, theme_id) do
    %ThemeCustomizationSchema{
      profile_id: profile_id,
      theme_id: theme_id,
      settings: get_defaults(theme_id)
    }
  end

  @doc """
  The render tokens for a theme: the saved settings as the spec reads them
  (`Specs.settings/2`: the theme's defaults when nothing is saved, and a
  group's defaults in place of settings it no longer accepts) plus any
  per-request overrides, through the theme's customisation spec.
  """
  @spec tokens(theme_id(), ThemeCustomizationSchema.t() | nil, Palette.overrides()) ::
          Tokens.t()
  def tokens(theme_id, customization, overrides \\ %{}) do
    spec = Specs.for_theme(theme_id)
    spec.tokens(Specs.settings(spec, to_map(customization)), overrides)
  end

  # New orchestrator functions for component interface

  @doc """
  The customisation the dashboard starts from: the saved one, or the theme's
  defaults unsaved, with its settings as the booking page reads them
  (`Specs.settings/2`), plus the saved original as stored.
  """
  @spec initialize_customization(profile_id(), theme_id()) :: %{
          customization: ThemeCustomizationSchema.t(),
          original: ThemeCustomizationSchema.t()
        }
  def initialize_customization(profile_id, theme_id) do
    saved = get_by_profile_and_theme(profile_id, theme_id)
    current = saved || default_customization(profile_id, theme_id)
    settings = Specs.settings(Specs.for_theme(theme_id), to_map(current))

    %{customization: %{current | settings: settings}, original: saved || current}
  end

  @default_custom_palette_seed "#06b6d4"

  @doc """
  Returns the brand default seed hex used when a user first activates the
  custom-palette mode and has no previously stored seed.
  """
  @spec default_custom_palette_seed() :: String.t()
  def default_custom_palette_seed, do: @default_custom_palette_seed

  @doc """
  Applies one option change from the customisation panel.

  `option_key` names one of the theme spec's `option_groups/0`; `params` is
  `%{"field" => field, "value" => value}` (the group's module says which it
  accepts, through `OptionGroup.changes/3`). The change goes through the spec
  changeset, so an option or value the theme does not support is refused; a
  stale value in another group never refuses it (`Specs.settings/2`).
  Returns a translated message on failure.
  """
  @spec apply_option(profile_id(), theme_id(), atom(), map()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_option(profile_id, theme_id, option_key, %{"field" => field, "value" => value})
      when is_binary(field) and is_binary(value) do
    with {:ok, group} <- option_group(theme_id, option_key),
         {:ok, changes} <- group.module.changes(field, value, group) do
      # The save starts from the stored settings as `Specs.settings/2` reads
      # them (the schema changeset), so only the change is passed and only
      # its group is judged. The update deletes any upload the change stops
      # naming (`update_theme_customization/2`).
      profile_id
      |> upsert_theme_customization(theme_id, changes)
      |> format_persistence_error()
    else
      :error -> {:error, option_unavailable()}
    end
  end

  def apply_option(_profile_id, _theme_id, _option_key, _params),
    do: {:error, option_unavailable()}

  @doc "The theme spec's option groups, in panel order; empty for an unknown theme."
  @spec option_groups(theme_id()) :: [OptionGroup.group()]
  def option_groups(theme_id) do
    case Catalog.customization_spec(theme_id) do
      {:ok, spec} -> spec.option_groups()
      {:error, :theme_not_found} -> []
    end
  end

  @doc """
  What the onboarding wizard offers for a theme (`Spec.onboarding_choices/0`),
  or `nil` when its spec offers nothing. An unknown theme reads the default
  theme's spec.
  """
  @spec onboarding_choices(theme_id()) :: Spec.onboarding_choices()
  def onboarding_choices(theme_id) do
    spec = Specs.for_theme(theme_id)

    # Optional callback: a spec written without `use Spec` may leave it out.
    # `ensure_loaded?/1` first, because in dev and test a module is loaded on
    # first use and `function_exported?/3` is false until then.
    if Code.ensure_loaded?(spec) and function_exported?(spec, :onboarding_choices, 0),
      do: spec.onboarding_choices(),
      else: nil
  end

  defp option_group(theme_id, key) do
    case Enum.find(option_groups(theme_id), &(&1.key == key)) do
      nil -> :error
      group -> {:ok, group}
    end
  end

  defp option_unavailable,
    do: dgettext("dashboard_appearance", "This option is not available for this theme.")

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

  # Private functions

  # Converts a rejected write (an invalid changeset or an invalid seed) into a
  # user-safe string. Callers flash the returned message, and `Flash.error/1`
  # guards on binaries, so a raw changeset would crash the component.
  @spec format_persistence_error({:ok, ThemeCustomizationSchema.t()} | {:error, term()}) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  defp format_persistence_error({:ok, _result} = ok), do: ok

  defp format_persistence_error({:error, _reason}),
    do:
      {:error,
       dgettext(
         "dashboard_appearance",
         "Could not save your theme customisation. Please try again."
       )}
end
