defmodule Tymeslot.Integrations.Shared.ProviderConfigHelper do
  @moduledoc """
  Shared helper functions for provider configuration modules.

  Provides common patterns for filtering enabled providers and handling
  development-only providers.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Calculates effective providers list, filtering by enabled status and optionally including dev providers.

  ## Parameters
  - `providers`: List of all provider atoms
  - `dev_only_providers`: List of development-only provider atoms
  - `include_dev`: Boolean indicating whether to include dev providers
  - `provider_enabled_fun`: Function that takes a provider atom and returns boolean

  ## Returns
  List of enabled provider atoms
  """
  @spec effective_providers(
          list(atom()),
          list(atom()),
          boolean(),
          (atom() -> boolean())
        ) :: list(atom())
  def effective_providers(providers, dev_only_providers, include_dev, provider_enabled_fun) do
    base = Enum.filter(providers, provider_enabled_fun)

    dev =
      if include_dev and Application.get_env(:tymeslot, :environment) in [:dev, :test] do
        Enum.filter(dev_only_providers, provider_enabled_fun)
      else
        []
      end

    base ++ dev
  end

  @doc """
  Validates that a config map contains all required fields, for calendar and
  video providers alike.

  Returns `:ok`, or the translated error from `missing_fields_error/1`.
  """
  @spec validate_required_fields(%{atom() => term()}, list(atom())) :: :ok | {:error, String.t()}
  def validate_required_fields(config, required_fields) do
    case required_fields -- Map.keys(config) do
      [] -> :ok
      missing_fields -> missing_fields_error(missing_fields)
    end
  end

  @doc """
  The error for a provider configuration missing `fields`, in the user's
  language. One message for every provider family, so the wording does not
  depend on which kind of integration is being set up.
  """
  @spec missing_fields_error([atom() | String.t()]) :: {:error, String.t()}
  def missing_fields_error(fields) do
    {:error,
     dgettext("integrations", "Missing required fields: %{fields}",
       fields: Enum.join(fields, ", ")
     )}
  end
end
