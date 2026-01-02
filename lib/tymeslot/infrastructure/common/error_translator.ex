defmodule Tymeslot.Infrastructure.Common.ErrorTranslator do
  @moduledoc """
  Translates technical integration errors into user-friendly messages with actionable resolution steps.

  This module provides:
  - Human-readable error messages
  - Actionable resolution steps
  - Error categorization (transient vs permanent)
  - Context-aware error handling
  """

  # Error categories
  @type error_category ::
          :authentication
          | :network
          | :permission
          | :configuration
          | :rate_limit
          | :server
          | :unknown
  @type error_severity :: :transient | :permanent

  @type translated_error :: %{
          message: String.t(),
          details: String.t(),
          category: error_category(),
          severity: error_severity(),
          resolution_steps: list(String.t()),
          retry_after: pos_integer() | nil,
          support_reference: String.t() | nil
        }

  @doc """
  Translates an integration error into a user-friendly format.
  """
  @spec translate_error(atom() | String.t(), String.t(), map()) :: translated_error()
  def translate_error(error, provider, context \\ %{})

  # OAuth and Authentication Errors
  def translate_error(:invalid_credentials, provider, _context) do
    %{
      message: "Authentication failed",
      details: "Your #{provider} credentials are invalid or have expired.",
      category: :authentication,
      severity: :permanent,
      resolution_steps: [
        "Go to your Dashboard > Integrations",
        "Find the #{provider} integration",
        "Click 'Reconnect' to re-authenticate",
        "Follow the authorization flow to grant permissions"
      ],
      retry_after: nil,
      support_reference: "AUTH001"
    }
  end

  def translate_error(:token_expired, provider, _context) do
    %{
      message: "Access token expired",
      details: "Your #{provider} access token has expired and needs to be refreshed.",
      category: :authentication,
      severity: :transient,
      resolution_steps: [
        "The system will automatically attempt to refresh your token",
        "If this persists, try reconnecting the integration"
      ],
      retry_after: 5,
      support_reference: "AUTH002"
    }
  end

  def translate_error(:insufficient_permissions, provider, context) do
    missing_scopes = Map.get(context, :missing_scopes, [])

    scope_list =
      if length(missing_scopes) > 0,
        do: Enum.join(missing_scopes, ", "),
        else: "required permissions"

    %{
      message: "Insufficient permissions",
      details: "The #{provider} integration lacks permissions: #{scope_list}",
      category: :permission,
      severity: :permanent,
      resolution_steps: [
        "Reconnect the #{provider} integration",
        "When prompted, grant all requested permissions",
        "Ensure you don't uncheck any permission requests",
        "Contact your #{provider} administrator if you can't grant permissions"
      ],
      retry_after: nil,
      support_reference: "PERM001"
    }
  end

  # Network and Connectivity Errors
  def translate_error(:timeout, provider, _context) do
    %{
      message: "Connection timeout",
      details: "Unable to reach #{provider} servers within the time limit.",
      category: :network,
      severity: :transient,
      resolution_steps: [
        "Check your internet connection",
        "Try again in a few moments",
        "If the issue persists, #{provider} may be experiencing high load"
      ],
      retry_after: 30,
      support_reference: "NET001"
    }
  end

  def translate_error(:connection_refused, provider, _context) do
    %{
      message: "Connection refused",
      details: "Unable to connect to #{provider}.",
      category: :network,
      severity: :transient,
      resolution_steps: [
        "Verify your internet connection",
        "Check if #{provider} is accessible from your browser",
        "Your firewall or proxy may be blocking the connection",
        "Try again in a few minutes"
      ],
      retry_after: 60,
      support_reference: "NET002"
    }
  end

  def translate_error({:http_error, status}, provider, _context) when status >= 500 do
    %{
      message: "Server error at #{provider}",
      details: "#{provider} is experiencing technical difficulties (Error #{status}).",
      category: :server,
      severity: :transient,
      resolution_steps: [
        "This is a temporary issue with #{provider}",
        "Please try again in a few minutes",
        "Check #{provider}'s status page for any ongoing incidents"
      ],
      retry_after: 300,
      support_reference: "SRV#{status}"
    }
  end

  def translate_error({:http_error, 429}, provider, context) do
    retry_after = Map.get(context, :retry_after_seconds, 3600)

    %{
      message: "Rate limit exceeded",
      details: "Too many requests to #{provider}. Please wait before trying again.",
      category: :rate_limit,
      severity: :transient,
      resolution_steps: [
        "Wait #{format_duration(retry_after)} before trying again",
        "Reduce the frequency of your requests",
        "Consider upgrading your #{provider} plan for higher limits"
      ],
      retry_after: retry_after,
      support_reference: "RATE001"
    }
  end

  def translate_error({:http_error, 404}, provider, context) do
    resource = Map.get(context, :resource, "resource")

    %{
      message: "#{String.capitalize(resource)} not found",
      details: "The requested #{resource} was not found in #{provider}.",
      category: :configuration,
      severity: :permanent,
      resolution_steps: [
        "Verify the #{resource} exists in #{provider}",
        "Check if you have access to this #{resource}",
        "The #{resource} may have been deleted or moved"
      ],
      retry_after: nil,
      support_reference: "RES404"
    }
  end

  # Configuration Errors
  def translate_error(:invalid_base_url, provider, context) do
    url = Map.get(context, :url, "the provided URL")

    %{
      message: "Invalid server URL",
      details: "The #{provider} server URL is not valid: #{url}",
      category: :configuration,
      severity: :permanent,
      resolution_steps: [
        "Check the URL format (should start with https:// or http://)",
        "Ensure there are no typos in the URL",
        "Verify the server is accessible",
        "For self-hosted services, confirm with your administrator"
      ],
      retry_after: nil,
      support_reference: "CONF001"
    }
  end

  def translate_error(:calendar_not_found, provider, context) do
    calendar_name = Map.get(context, :calendar_name, "calendar")

    %{
      message: "Calendar not found",
      details: "Unable to find '#{calendar_name}' in your #{provider} account.",
      category: :configuration,
      severity: :permanent,
      resolution_steps: [
        "Verify the calendar name is correct",
        "Check if the calendar exists in your #{provider} account",
        "Ensure you have access permissions for this calendar",
        "Try selecting a different calendar"
      ],
      retry_after: nil,
      support_reference: "CAL001"
    }
  end

  # Video Provider Specific Errors
  def translate_error(:video_provider_not_configured, provider, _context) do
    %{
      message: "Video provider not configured",
      details: "#{provider} video integration requires additional setup.",
      category: :configuration,
      severity: :permanent,
      resolution_steps: [
        "Go to Dashboard > Video Integrations",
        "Complete the #{provider} setup process",
        "Ensure all required fields are filled",
        "Test the connection after configuration"
      ],
      retry_after: nil,
      support_reference: "VID001"
    }
  end

  def translate_error(:meeting_creation_failed, provider, context) do
    reason = Map.get(context, :reason, "Unknown reason")

    %{
      message: "Failed to create meeting",
      details: "Could not create a #{provider} meeting: #{reason}",
      category: :server,
      severity: :transient,
      resolution_steps: [
        "Verify your #{provider} account has meeting creation permissions",
        "Check if you've reached your meeting limit",
        "Try again in a few moments",
        "Contact support if the issue persists"
      ],
      retry_after: 60,
      support_reference: "VID002"
    }
  end

  # Generic/Unknown Errors
  def translate_error(error, provider, _context) when is_binary(error) do
    %{
      message: "Integration error",
      details: "#{provider} error: #{error}",
      category: :unknown,
      severity: :transient,
      resolution_steps: [
        "Try again in a few moments",
        "Check your integration settings",
        "If the issue persists, contact support with reference code"
      ],
      retry_after: 60,
      support_reference: generate_support_reference(error)
    }
  end

  def translate_error(error, provider, _context) do
    %{
      message: "Unexpected error",
      details: "An unexpected error occurred with #{provider}: #{inspect(error)}",
      category: :unknown,
      severity: :transient,
      resolution_steps: [
        "Try again in a few moments",
        "If the issue persists, try reconnecting the integration",
        "Contact support with the reference code below"
      ],
      retry_after: 60,
      support_reference: generate_support_reference(error)
    }
  end

  @doc """
  Categorizes an error based on its type and content.
  """
  @spec categorize_error(any()) :: error_category()
  def categorize_error(error) do
    cond do
      authentication_error?(error) -> :authentication
      network_error?(error) -> :network
      permission_error?(error) -> :permission
      configuration_error?(error) -> :configuration
      rate_limit_error?(error) -> :rate_limit
      server_error?(error) -> :server
      true -> :unknown
    end
  end

  @doc """
  Determines if an error should trigger an automatic retry.
  """
  @spec should_retry?(translated_error()) :: boolean()
  def should_retry?(%{severity: :transient, retry_after: retry_after})
      when not is_nil(retry_after) do
    true
  end

  def should_retry?(_), do: false

  @doc """
  Formats an error for display to the user.
  """
  @spec format_user_message(translated_error()) :: String.t()
  def format_user_message(error) do
    steps =
      if length(error.resolution_steps) > 0 do
        "\n\nWhat to do:\n" <>
          Enum.map_join(error.resolution_steps, "\n", fn step -> "• #{step}" end)
      else
        ""
      end

    reference =
      if error.support_reference do
        "\n\nSupport Reference: #{error.support_reference}"
      else
        ""
      end

    "#{error.message}\n\n#{error.details}#{steps}#{reference}"
  end

  # Private helper functions

  defp authentication_error?(error) do
    case error do
      :invalid_credentials -> true
      :token_expired -> true
      :unauthorized -> true
      {:http_error, 401} -> true
      _ -> false
    end
  end

  defp network_error?(error) do
    case error do
      :timeout -> true
      :connection_refused -> true
      :nxdomain -> true
      {:error, :closed} -> true
      {:error, :econnrefused} -> true
      _ -> false
    end
  end

  defp permission_error?(error) do
    case error do
      :insufficient_permissions -> true
      :access_denied -> true
      {:http_error, 403} -> true
      _ -> false
    end
  end

  defp configuration_error?(error) do
    case error do
      :invalid_base_url -> true
      :calendar_not_found -> true
      :invalid_configuration -> true
      {:http_error, 404} -> true
      _ -> false
    end
  end

  defp rate_limit_error?(error) do
    case error do
      :rate_limited -> true
      {:http_error, 429} -> true
      _ -> false
    end
  end

  defp server_error?(error) do
    case error do
      {:http_error, status} when status >= 500 -> true
      :server_error -> true
      _ -> false
    end
  end

  defp format_duration(seconds) when seconds < 60 do
    "#{seconds} seconds"
  end

  defp format_duration(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    "#{minutes} minute#{if minutes != 1, do: "s", else: ""}"
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    "#{hours} hour#{if hours != 1, do: "s", else: ""}"
  end

  defp generate_support_reference(error) do
    error_string = inspect(error)
    hash = String.slice(Base.encode16(:crypto.hash(:md5, error_string)), 0, 8)
    "ERR-#{hash}"
  end
end
