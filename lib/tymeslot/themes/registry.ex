defmodule Tymeslot.Themes.Registry do
  @moduledoc """
  Backward compatibility module for the old Registry location.

  This module delegates to the new TymeslotWeb.Themes.Core.Registry.
  Consider this deprecated - use TymeslotWeb.Themes.Core.Registry directly.
  """

  defdelegate all_themes(), to: TymeslotWeb.Themes.Core.Registry
  defdelegate active_themes(), to: TymeslotWeb.Themes.Core.Registry
  defdelegate get_theme_by_id(id), to: TymeslotWeb.Themes.Core.Registry
  defdelegate get_theme_by_id!(id), to: TymeslotWeb.Themes.Core.Registry
  defdelegate get_theme_by_key(key), to: TymeslotWeb.Themes.Core.Registry
  defdelegate get_theme_by_key!(key), to: TymeslotWeb.Themes.Core.Registry
  defdelegate id_to_key(id), to: TymeslotWeb.Themes.Core.Registry
  defdelegate key_to_id(key), to: TymeslotWeb.Themes.Core.Registry
  defdelegate valid_theme_ids(), to: TymeslotWeb.Themes.Core.Registry
  defdelegate valid_theme_keys(), to: TymeslotWeb.Themes.Core.Registry
  defdelegate valid_theme_id?(id), to: TymeslotWeb.Themes.Core.Registry
  defdelegate valid_theme_key?(key), to: TymeslotWeb.Themes.Core.Registry
  defdelegate default_theme(), to: TymeslotWeb.Themes.Core.Registry
  defdelegate default_theme_id(), to: TymeslotWeb.Themes.Core.Registry
  defdelegate default_theme_key(), to: TymeslotWeb.Themes.Core.Registry
  defdelegate themes_with_feature(feature), to: TymeslotWeb.Themes.Core.Registry
  defdelegate get_module_by_id(id), to: TymeslotWeb.Themes.Core.Registry
  defdelegate get_css_file_by_id(id), to: TymeslotWeb.Themes.Core.Registry
end
