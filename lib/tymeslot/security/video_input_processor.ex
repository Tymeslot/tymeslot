defmodule Tymeslot.Security.VideoInputProcessor do
  @moduledoc """
  Video integration input validation and sanitization.

  Provides specialized validation for video integration forms including
  MiroTalk and Custom Video configuration forms.
  """

  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}
  alias Tymeslot.Security.{SharedInputValidators, UrlValidation}

  @doc """
  Validates video integration form input based on provider type.

  ## Parameters
  - `params` - Map containing video integration form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_video_integration_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_video_integration_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    provider = params["provider"]

    case provider do
      "mirotalk" ->
        validate_mirotalk_form(params, metadata)

      "custom" ->
        validate_custom_video_form(params, metadata)

      _ ->
        SecurityLogger.log_security_event("video_integration_unknown_provider", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          provider: provider
        })

        {:error, %{provider: "Unknown video provider"}}
    end
  end

  # Private validation functions for each provider type

  defp validate_mirotalk_form(params, metadata) do
    with {:ok, sanitized_name} <-
           SharedInputValidators.validate_integration_name(params["name"], metadata),
         {:ok, sanitized_api_key} <- validate_api_key(params["api_key"], metadata),
         {:ok, sanitized_base_url} <- validate_base_url(params["base_url"], metadata) do
      SecurityLogger.log_security_event("mirotalk_integration_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id]
      })

      {:ok,
       %{
         "name" => sanitized_name,
         "api_key" => sanitized_api_key,
         "base_url" => sanitized_base_url
       }}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("mirotalk_integration_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  defp validate_custom_video_form(params, metadata) do
    with {:ok, sanitized_name} <-
           SharedInputValidators.validate_integration_name(params["name"], metadata),
         {:ok, sanitized_meeting_url} <-
           validate_meeting_url(params["custom_meeting_url"], metadata) do
      SecurityLogger.log_security_event("custom_video_integration_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id]
      })

      {:ok,
       %{
         "name" => sanitized_name,
         "custom_meeting_url" => sanitized_meeting_url
       }}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("custom_video_integration_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  # Helper validation functions

  defp validate_api_key(nil, _metadata), do: {:error, %{api_key: "API key is required"}}
  defp validate_api_key("", _metadata), do: {:error, %{api_key: "API key is required"}}

  defp validate_api_key(api_key, metadata) when is_binary(api_key) do
    case UniversalSanitizer.sanitize_and_validate(api_key, allow_html: false, metadata: metadata) do
      {:ok, sanitized_api_key} ->
        cond do
          String.length(sanitized_api_key) > 500 ->
            {:error, %{api_key: "API key must be 500 characters or less"}}

          String.length(String.trim(sanitized_api_key)) < 8 ->
            {:error, %{api_key: "API key must be at least 8 characters"}}

          true ->
            {:ok, String.trim(sanitized_api_key)}
        end

      {:error, error} ->
        {:error, %{api_key: error}}
    end
  end

  defp validate_api_key(_, _metadata) do
    {:error, %{api_key: "API key must be text"}}
  end

  defp validate_base_url(nil, _metadata), do: {:error, %{base_url: "Base URL is required"}}
  defp validate_base_url("", _metadata), do: {:error, %{base_url: "Base URL is required"}}

  defp validate_base_url(base_url, metadata) when is_binary(base_url) do
    case UniversalSanitizer.sanitize_and_validate(base_url, allow_html: false, metadata: metadata) do
      {:ok, sanitized_url} ->
        case validate_video_url(sanitized_url) do
          :ok -> {:ok, sanitized_url}
          {:error, error} -> {:error, %{base_url: error}}
        end

      {:error, error} ->
        {:error, %{base_url: error}}
    end
  end

  defp validate_base_url(_, _metadata) do
    {:error, %{base_url: "Base URL must be text"}}
  end

  defp validate_meeting_url(nil, _metadata),
    do: {:error, %{custom_meeting_url: "Meeting URL is required"}}

  defp validate_meeting_url("", _metadata),
    do: {:error, %{custom_meeting_url: "Meeting URL is required"}}

  defp validate_meeting_url(meeting_url, metadata) when is_binary(meeting_url) do
    case UniversalSanitizer.sanitize_and_validate(meeting_url,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_url} ->
        case validate_video_url(sanitized_url) do
          :ok -> {:ok, sanitized_url}
          {:error, error} -> {:error, %{custom_meeting_url: error}}
        end

      {:error, error} ->
        {:error, %{custom_meeting_url: error}}
    end
  end

  defp validate_meeting_url(_, _metadata) do
    {:error, %{custom_meeting_url: "Meeting URL must be text"}}
  end

  defp validate_video_url(url) do
    UrlValidation.validate_http_url(url,
      extra_checks: &validate_external_video_host/1,
      disallowed_protocol_error: "Only HTTP and HTTPS URLs are allowed",
      invalid_message: "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"
    )
  end

  defp validate_external_video_host(%{host: host}) do
    if video_host_allowed?(host) do
      :ok
    else
      {:error, "Invalid hostname in URL"}
    end
  end

  defp video_host_allowed?(host) do
    cond do
      String.contains?(host, ["localhost", "127.0.0.1", "0.0.0.0"]) and
          not String.contains?(host, ["meet.localhost"]) ->
        false

      String.contains?(host, ["<", ">", "\"", "'", "&"]) ->
        false

      String.length(host) > 253 ->
        false

      true ->
        true
    end
  end
end
