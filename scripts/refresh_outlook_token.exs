#!/usr/bin/env elixir

# Script to manually refresh Outlook OAuth token
# Usage: elixir scripts/refresh_outlook_token.exs [integration_id]

require Logger

alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI

# Get integration ID from command line args, default to 13
integration_id = case System.argv() do
  [id_str] -> String.to_integer(id_str)
  _ -> 13
end

Logger.info("Starting manual token refresh for Outlook integration ID: #{integration_id}")

# Get the integration
case CalendarIntegrationQueries.get(integration_id) do
  {:error, :not_found} ->
    Logger.error("Integration not found with ID: #{integration_id}")
    exit(:integration_not_found)
    
  {:ok, integration} ->
    if integration.provider != "outlook" do
      Logger.error("Integration #{integration_id} is not an Outlook integration (provider: #{integration.provider})")
      exit(:wrong_provider)
    end
    
    Logger.info("Found integration: #{integration.name} for user #{integration.user_id}")
    Logger.info("Provider: #{integration.provider}")
    
    # Check current token status
    now = DateTime.utc_now()
    expires_at = integration.token_expires_at
    
    if expires_at do
      Logger.info("Current token expires at: #{expires_at}")
      
      if DateTime.compare(now, expires_at) == :gt do
        Logger.info("Token is EXPIRED, refreshing...")
      else
        time_until_expiry = DateTime.diff(expires_at, now, :hour)
        Logger.info("Token still valid for #{time_until_expiry} hours")
      end
    else
      Logger.info("No token expiration time set")
    end
    
    # Attempt to refresh the token
    Logger.info("Attempting to refresh token...")
    
    case CalendarAPI.refresh_token(integration) do
      {:ok, {_access_token, _refresh_token, new_expires_at}} ->
        Logger.info("Token refresh successful!")
        Logger.info("New token expires at: #{new_expires_at}")
        
        # Verify the integration was updated in database
        case CalendarIntegrationQueries.get(integration_id) do
          {:ok, updated_integration} ->
            Logger.info("Database verification:")
            Logger.info("  - Token expires at: #{updated_integration.token_expires_at}")
            Logger.info("  - Integration is active: #{updated_integration.is_active}")
            Logger.info("  - Sync error: #{updated_integration.sync_error || "none"}")
          _ ->
            Logger.warning("Could not verify database update")
        end
        
      {:error, error_type, message} ->
        Logger.error("Failed to refresh token (#{error_type}): #{message}")
        exit(:token_refresh_failed)
        
      {:error, reason} ->
        Logger.error("Failed to refresh token: #{inspect(reason)}")
        exit(:token_refresh_failed)
    end
end

Logger.info("Script completed successfully")