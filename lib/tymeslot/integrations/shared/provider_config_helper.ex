defmodule Tymeslot.Integrations.Shared.ProviderConfigHelper do
  @moduledoc """
  Shared helper functions for provider configuration modules.

  Provides common patterns for filtering enabled providers and handling
  development-only providers.
  """

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
  Validates that a config map contains all required fields.

  ## Parameters
  - `config`: Configuration map to validate
  - `required_fields`: List of required field atoms

  ## Returns
  - `:ok` if all required fields are present
  - `{:error, String.t()}` with missing fields if validation fails
  """
  @spec validate_required_fields(map(), list(atom())) :: :ok | {:error, String.t()}
  def validate_required_fields(config, required_fields) do
    missing_fields = required_fields -- Map.keys(config)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end
end
