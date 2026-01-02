defmodule Tymeslot.Integrations.Common.UserResolver do
  @moduledoc """
  Common user resolution and integration management utilities.

  This module consolidates the common patterns for resolving user integrations,
  creating and updating integration records, and managing user-specific configuration.
  """

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.Integrations.Common.ErrorHandler

  @type integration_type :: :calendar | :video
  @type integration_attrs :: map()
  @type integration_result ::
          {:ok, CalendarIntegrationSchema.t() | VideoIntegrationSchema.t()} | {:error, String.t()}

  @doc """
  Resolves user integrations from the database with backward compatibility support.

  This function handles the common pattern of retrieving integrations by user ID
  while supporting both new user-based integrations and legacy singleton integrations.

  ## Examples

      resolve_user_integrations(123, :calendar)
      # => [%CalendarIntegrationSchema{...}]

      resolve_user_integrations(nil, :calendar)  # Legacy support
      # => [%CalendarIntegrationSchema{...}]
  """
  @spec resolve_user_integrations(integer() | nil, integration_type()) ::
          list(CalendarIntegrationSchema.t()) | list(VideoIntegrationSchema.t())
  def resolve_user_integrations(user_id, integration_type)
      when integration_type in [:calendar, :video] do
    ErrorHandler.handle_with_logging(
      fn -> get_integrations_from_database(user_id, integration_type) end,
      operation: "resolve user integrations",
      provider: to_string(integration_type),
      log_level: :warning
    )
  end

  @doc """
  Creates or updates an integration for a user.

  This handles the common pattern of checking if an integration exists and either
  creating or updating it accordingly. It provides consistent error handling and
  validation across all integration types.

  ## Examples

      create_or_update_integration(123, :calendar, "google", %{
        name: "Google Calendar",
        access_token: "token123",
        # ... other attributes
      })
  """
  @spec create_or_update_integration(
          integer(),
          integration_type(),
          String.t(),
          integration_attrs()
        ) :: integration_result()
  def create_or_update_integration(user_id, integration_type, provider_name, attrs)
      when integration_type in [:calendar, :video] and is_binary(provider_name) and is_map(attrs) do
    ErrorHandler.handle_with_logging(
      fn -> do_create_or_update_integration(user_id, integration_type, provider_name, attrs) end,
      operation: "create or update integration",
      provider: provider_name,
      log_level: :error
    )
  end

  @doc """
  Creates an OAuth-based integration with token information.

  Specifically designed for OAuth providers like Google and Outlook that need
  token management. This is a specialized version of create_or_update_integration
  for OAuth use cases.

  ## Examples

      create_oauth_integration(123, :calendar, "google", %{
        name: "Google Calendar",
        base_url: "https://www.googleapis.com/calendar/v3"
      }, %{
        access_token: "token123",
        refresh_token: "refresh123",
        expires_at: ~U[2024-12-31 23:59:59Z],
        scope: "calendar.readonly"
      })
  """
  @spec create_oauth_integration(integer(), integration_type(), String.t(), map(), map()) ::
          integration_result()
  def create_oauth_integration(user_id, integration_type, provider_name, provider_config, tokens)
      when integration_type in [:calendar, :video] and is_binary(provider_name) and
             is_map(provider_config) and is_map(tokens) do
    attrs =
      Map.merge(provider_config, %{
        user_id: user_id,
        provider: provider_name,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        token_expires_at: tokens.expires_at,
        oauth_scope: tokens.scope,
        is_active: true
      })

    create_or_update_integration(user_id, integration_type, provider_name, attrs)
  end

  @doc """
  Gets an integration by user ID and provider name.

  ## Examples

      get_integration_by_user_and_provider(123, :calendar, "google")
      # => {:ok, %CalendarIntegrationSchema{...}} | {:error, "not found"}
  """
  @spec get_integration_by_user_and_provider(integer(), integration_type(), String.t()) ::
          integration_result()
  def get_integration_by_user_and_provider(user_id, integration_type, provider_name)
      when integration_type in [:calendar, :video] and is_binary(provider_name) do
    case integration_type do
      :calendar ->
        cal_result = CalendarIntegrationQueries.get_by_user_and_provider(user_id, provider_name)

        case cal_result do
          {:error, :not_found} -> {:error, "Integration not found"}
          {:ok, integration} -> {:ok, integration}
        end

      :video ->
        # Video integrations don't have provider-based queries, so we filter
        vid_integration =
          user_id
          |> VideoIntegrationQueries.list_all_for_user()
          |> Enum.find(fn integration -> integration.provider == provider_name end)

        case vid_integration do
          nil -> {:error, "Integration not found"}
          integration -> {:ok, integration}
        end
    end
  end

  @doc """
  Lists all integrations for a user by type.

  ## Examples

      list_user_integrations(123, :calendar)
      # => {:ok, [%CalendarIntegrationSchema{...}]}
  """
  @spec list_user_integrations(integer(), integration_type()) ::
          {:ok, list(CalendarIntegrationSchema.t() | VideoIntegrationSchema.t())}
          | {:error, String.t()}
  def list_user_integrations(user_id, integration_type)
      when integration_type in [:calendar, :video] do
    ErrorHandler.handle_with_logging(
      fn ->
        integrations = get_integrations_from_database(user_id, integration_type)
        {:ok, integrations}
      end,
      operation: "list user integrations",
      provider: to_string(integration_type),
      log_level: :warning
    )
  end

  @doc """
  Updates an existing integration with new attributes.

  Provides consistent error handling and validation for integration updates.

  ## Examples

      update_integration(integration, %{access_token: "new_token"})
  """
  @spec update_integration(
          CalendarIntegrationSchema.t() | VideoIntegrationSchema.t(),
          integration_attrs()
        ) :: integration_result()
  def update_integration(integration, attrs) when is_map(attrs) do
    ErrorHandler.handle_with_logging(
      fn -> do_update_integration(integration, attrs) end,
      operation: "update integration",
      provider: integration.provider,
      log_level: :error
    )
  end

  @doc """
  Validates integration attributes against common requirements.

  Checks for required fields and validates common patterns across different
  integration types.
  """
  @spec validate_integration_attrs(integration_attrs(), integration_type()) ::
          :ok | {:error, String.t()}
  def validate_integration_attrs(attrs, integration_type)
      when is_map(attrs) and integration_type in [:calendar, :video] do
    required_fields = get_required_fields(integration_type)

    missing_fields =
      required_fields
      |> Enum.reject(&Map.has_key?(attrs, &1))
      |> Enum.map(&to_string/1)

    case missing_fields do
      [] -> validate_integration_specific_attrs(attrs, integration_type)
      fields -> {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  @doc """
  Generates default integration attributes for a provider.

  Creates sensible defaults for common integration attributes based on the
  provider type and integration type.
  """
  @spec default_integration_attrs(integration_type(), String.t()) :: integration_attrs()
  def default_integration_attrs(integration_type, provider_name)
      when integration_type in [:calendar, :video] and is_binary(provider_name) do
    base_attrs = %{
      is_active: true,
      provider: provider_name,
      sync_error: nil
    }

    case integration_type do
      :calendar ->
        Map.merge(base_attrs, %{
          name: "#{String.capitalize(provider_name)} Calendar"
        })

      :video ->
        Map.merge(base_attrs, %{
          name: "#{String.capitalize(provider_name)} Video"
        })
    end
  end

  # Private functions

  defp get_integrations_from_database(user_id, :calendar) do
    if user_id do
      CalendarIntegrationQueries.list_all_for_user(user_id)
    else
      # Legacy support: if no user_id provided, get all integrations for user 1 as fallback
      # This maintains backward compatibility with existing code
      CalendarIntegrationQueries.list_all_for_user(1)
    end
  end

  defp get_integrations_from_database(user_id, :video) do
    if user_id do
      VideoIntegrationQueries.list_all_for_user(user_id)
    else
      # Legacy support: if no user_id provided, get all integrations for user 1 as fallback
      VideoIntegrationQueries.list_all_for_user(1)
    end
  end

  defp do_create_or_update_integration(user_id, :calendar, provider_name, attrs) do
    case CalendarIntegrationQueries.get_by_user_and_provider(user_id, provider_name) do
      {:error, :not_found} ->
        ErrorHandler.handle_database_error(CalendarIntegrationQueries.create(attrs))

      {:ok, existing_integration} ->
        ErrorHandler.handle_database_error(
          CalendarIntegrationQueries.update(existing_integration, attrs)
        )
    end
  end

  defp do_create_or_update_integration(user_id, :video, provider_name, attrs) do
    # Video integrations don't have provider-based queries, so we filter manually
    existing_integration =
      user_id
      |> VideoIntegrationQueries.list_all_for_user()
      |> Enum.find(fn integration -> integration.provider == provider_name end)

    case existing_integration do
      nil ->
        ErrorHandler.handle_database_error(VideoIntegrationQueries.create(attrs))

      integration ->
        ErrorHandler.handle_database_error(VideoIntegrationQueries.update(integration, attrs))
    end
  end

  defp do_update_integration(%CalendarIntegrationSchema{} = integration, attrs) do
    ErrorHandler.handle_database_error(CalendarIntegrationQueries.update(integration, attrs))
  end

  defp do_update_integration(%VideoIntegrationSchema{} = integration, attrs) do
    ErrorHandler.handle_database_error(VideoIntegrationQueries.update(integration, attrs))
  end

  defp get_required_fields(:calendar) do
    [:user_id, :name, :provider, :is_active]
  end

  defp get_required_fields(:video) do
    [:user_id, :name, :provider, :is_active]
  end

  defp validate_integration_specific_attrs(attrs, :calendar) do
    # Calendar-specific validation
    cond do
      attrs[:provider] in ["google", "outlook"] and not Map.has_key?(attrs, :access_token) ->
        {:error, "OAuth providers require access_token"}

      attrs[:provider] == "caldav" and not Map.has_key?(attrs, :base_url) ->
        {:error, "CalDAV providers require base_url"}

      true ->
        :ok
    end
  end

  defp validate_integration_specific_attrs(attrs, :video) do
    # Video-specific validation
    cond do
      attrs[:provider] in ["google_meet", "teams"] and not Map.has_key?(attrs, :access_token) ->
        {:error, "OAuth video providers require access_token"}

      attrs[:provider] == "zoom" and not Map.has_key?(attrs, :api_key) ->
        {:error, "Zoom provider requires api_key"}

      true ->
        :ok
    end
  end
end
