defmodule Tymeslot.Security.CalendarInputProcessor do
  @moduledoc """
  Calendar integration input validation and sanitization.

  Provides specialized validation for calendar integration forms including
  Nextcloud and CalDAV configuration forms with URL, credential, and path validation.
  """

  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}
  alias Tymeslot.Security.{SharedInputValidators, UrlValidation}

  @doc """
  Validates calendar integration form input (name, url, username, password, calendar_paths).

  ## Parameters
  - `params` - Map containing calendar integration form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_calendar_integration_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_calendar_integration_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_name} <-
           SharedInputValidators.validate_integration_name(params["name"], metadata),
         {:ok, sanitized_url} <- validate_server_url(params["url"], metadata),
         {:ok, sanitized_username} <- validate_username(params["username"], metadata),
         {:ok, sanitized_password} <- validate_password(params["password"], metadata),
         {:ok, sanitized_calendar_paths} <-
           validate_calendar_paths(params["calendar_paths"], metadata) do
      SecurityLogger.log_security_event("calendar_integration_form_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        provider: params["provider"]
      })

      {:ok,
       %{
         "name" => sanitized_name,
         "url" => sanitized_url,
         "username" => sanitized_username,
         "password" => sanitized_password,
         "calendar_paths" => sanitized_calendar_paths
       }}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("calendar_integration_form_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          provider: params["provider"],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Validates a single field for calendar integration form.

  ## Parameters
  - `field` - The field name as atom (:name, :url, :username, :password, :calendar_paths)
  - `value` - The field value to validate
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_value}` | `{:error, error_message}`
  """
  @spec validate_single_field(atom(), any(), keyword()) :: {:ok, any()} | {:error, binary()}
  def validate_single_field(field, value, opts \\ [])

  def validate_single_field(:name, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case SharedInputValidators.validate_integration_name(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{name: error}} -> {:error, error}
    end
  end

  def validate_single_field(:url, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_server_url(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{url: error}} -> {:error, error}
    end
  end

  def validate_single_field(:username, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_username(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{username: error}} -> {:error, error}
    end
  end

  def validate_single_field(:password, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_password(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{password: error}} -> {:error, error}
    end
  end

  def validate_single_field(:calendar_paths, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_calendar_paths(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{calendar_paths: error}} -> {:error, error}
    end
  end

  def validate_single_field(_, _, _), do: {:ok, nil}

  @doc """
  Validates Nextcloud calendar discovery parameters.

  ## Parameters
  - `params` - Map containing discovery parameters (url, username, password)
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_nextcloud_discovery(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_nextcloud_discovery(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    validate_discovery(params, metadata,
      success_event: "nextcloud_discovery_validation_success",
      failure_event: "nextcloud_discovery_validation_failure",
      extra_success_meta: fn sanitized ->
        %{url: sanitize_url_for_logging(sanitized["url"])}
      end
    )
  end

  @doc """
  Validates calendar discovery parameters for any CalDAV-based provider.

  Supports CalDAV, Radicale, Nextcloud, and other CalDAV-compatible providers.
  """
  @spec validate_calendar_discovery(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_calendar_discovery(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    provider = Keyword.get(opts, :provider, :caldav)

    normalize_url =
      case provider do
        :radicale -> &normalize_radicale_base_url_for_discovery/2
        _ -> fn url, _username -> url end
      end

    validate_discovery(params, metadata,
      success_event: "#{provider}_discovery_validation_success",
      failure_event: "#{provider}_discovery_validation_failure",
      normalize_url: normalize_url,
      extra_success_meta: fn sanitized ->
        %{url: sanitize_url_for_logging(sanitized["url"]), provider: provider}
      end,
      extra_failure_meta: fn _ -> %{provider: provider} end
    )
  end

  # Radicale-specific: sanitize common mistakes in base URL.
  # - If user included '/.web' (or '/.web/'), drop it.
  # - If user appended '/<username>' (with or without trailing slash), drop it.
  # - Always reduce to scheme://host[:port] (no path) for discovery base URL.
  defp normalize_radicale_base_url_for_discovery(url, _username) do
    url = String.trim(to_string(url))

    # Ensure scheme
    url =
      cond do
        String.starts_with?(url, "http://") or String.starts_with?(url, "https://") -> url
        String.starts_with?(url, "//") -> "https:" <> url
        true -> "https://" <> url
      end

    uri = URI.parse(url)

    # If host missing, return as-is (validation would have caught bad URLs earlier)
    if is_nil(uri.host) do
      url
    else
      port_suffix = if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""
      base = "#{uri.scheme || "https"}://#{uri.host}#{port_suffix}"

      # We intentionally drop any path (including '/.web' or '/<username>') and return base only
      base
    end
  end

  @doc """
  Validates CalDAV calendar discovery parameters.
  Delegates to the unified validation function for backward compatibility.
  """
  @spec validate_caldav_discovery(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_caldav_discovery(params, opts \\ []) do
    validate_calendar_discovery(params, Keyword.put(opts, :provider, :caldav))
  end

  @doc """
  Validates Radicale calendar discovery parameters.
  Delegates to the unified validation function for backward compatibility.
  """
  @spec validate_radicale_discovery(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_radicale_discovery(params, opts \\ []) do
    validate_calendar_discovery(params, Keyword.put(opts, :provider, :radicale))
  end

  # Private helper functions

  # Optional for some providers
  defp validate_server_url(nil, _metadata), do: {:ok, ""}
  defp validate_server_url("", _metadata), do: {:ok, ""}

  defp validate_server_url(url, metadata) when is_binary(url) do
    # Normalize URL by adding https:// if no protocol is present
    normalized_url = normalize_url_protocol(url)

    case UniversalSanitizer.sanitize_and_validate(normalized_url,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_url} ->
        case validate_calendar_url(sanitized_url) do
          :ok -> {:ok, sanitized_url}
          {:error, error} -> {:error, %{url: error}}
        end

      {:error, error} ->
        {:error, %{url: error}}
    end
  end

  defp validate_server_url(_, _metadata) do
    {:error, %{url: "Server URL must be text"}}
  end

  defp validate_username(nil, _metadata), do: {:error, %{username: "Username is required"}}
  defp validate_username("", _metadata), do: {:error, %{username: "Username is required"}}

  defp validate_username(username, metadata) when is_binary(username) do
    case UniversalSanitizer.sanitize_and_validate(username, allow_html: false, metadata: metadata) do
      {:ok, sanitized_username} ->
        cond do
          String.length(sanitized_username) > 255 ->
            {:error, %{username: "Username must be 255 characters or less"}}

          String.length(String.trim(sanitized_username)) < 1 ->
            {:error, %{username: "Username is required"}}

          true ->
            {:ok, String.trim(sanitized_username)}
        end

      {:error, error} ->
        {:error, %{username: error}}
    end
  end

  defp validate_username(_, _metadata) do
    {:error, %{username: "Username must be text"}}
  end

  defp validate_password(nil, _metadata), do: {:error, %{password: "Password is required"}}
  defp validate_password("", _metadata), do: {:error, %{password: "Password is required"}}

  defp validate_password(password, metadata) when is_binary(password) do
    case UniversalSanitizer.sanitize_and_validate(password, allow_html: false, metadata: metadata) do
      {:ok, sanitized_password} ->
        cond do
          String.length(sanitized_password) > 500 ->
            {:error, %{password: "Password must be 500 characters or less"}}

          String.length(String.trim(sanitized_password)) < 1 ->
            {:error, %{password: "Password is required"}}

          true ->
            {:ok, sanitized_password}
        end

      {:error, error} ->
        {:error, %{password: error}}
    end
  end

  defp validate_password(_, _metadata) do
    {:error, %{password: "Password must be text"}}
  end

  defp validate_calendar_paths(nil, _metadata), do: {:ok, ""}
  defp validate_calendar_paths("", _metadata), do: {:ok, ""}
  # Auto-discovery
  defp validate_calendar_paths("*", _metadata), do: {:ok, "*"}

  # Handle arrays by converting to comma-separated string
  defp validate_calendar_paths(calendar_paths, metadata) when is_list(calendar_paths) do
    validate_calendar_paths(Enum.join(calendar_paths, ","), metadata)
  end

  defp validate_calendar_paths(calendar_paths, metadata) when is_binary(calendar_paths) do
    case UniversalSanitizer.sanitize_and_validate(calendar_paths,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_paths} ->
        case validate_calendar_paths_format(sanitized_paths) do
          :ok -> {:ok, sanitized_paths}
          {:error, error} -> {:error, %{calendar_paths: error}}
        end

      {:error, error} ->
        {:error, %{calendar_paths: error}}
    end
  end

  defp validate_calendar_paths(_, _metadata) do
    {:error, %{calendar_paths: "Calendar paths must be text"}}
  end

  defp normalize_url_protocol(url) do
    trimmed_url = String.trim(url)

    cond do
      # Already has a protocol
      String.starts_with?(trimmed_url, ["http://", "https://"]) ->
        trimmed_url

      # No protocol - add https://
      trimmed_url != "" ->
        "https://" <> trimmed_url

      # Empty string
      true ->
        trimmed_url
    end
  end

  defp validate_calendar_paths_format(paths) do
    if String.length(paths) > 5000 do
      {:error, "Calendar paths must be 5000 characters or less"}
    else
      # Split by newlines OR commas and validate each path/URL
      separators = if String.contains?(paths, ","), do: [","], else: ["\n", "\r\n"]

      paths
      |> String.split(separators, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> validate_individual_paths()
    end
  end

  defp validate_individual_paths([]), do: :ok

  defp validate_individual_paths(paths) do
    invalid_paths = Enum.filter(paths, &invalid_path?/1)

    if Enum.empty?(invalid_paths) do
      :ok
    else
      {:error,
       "Some calendar paths have invalid format. Use full URLs (https://...) or paths (/calendar/)"}
    end
  end

  defp invalid_path?(path) do
    cond do
      String.starts_with?(path, ["http://", "https://"]) ->
        case validate_calendar_url(path) do
          :ok -> false
          _ -> true
        end

      String.starts_with?(path, "/") ->
        false

      true ->
        true
    end
  end

  # Helper to sanitize URL for logging (remove credentials)
  defp sanitize_url_for_logging(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | userinfo: nil})
  end

  defp validate_discovery(params, metadata, opts) do
    success_event = Keyword.fetch!(opts, :success_event)
    failure_event = Keyword.fetch!(opts, :failure_event)
    normalize_url = Keyword.get(opts, :normalize_url, fn url, _username -> url end)
    extra_success_meta = Keyword.get(opts, :extra_success_meta, fn _ -> %{} end)
    extra_failure_meta = Keyword.get(opts, :extra_failure_meta, fn _ -> %{} end)

    case validate_discovery_credentials(params, metadata) do
      {:ok, sanitized} ->
        normalized_url = normalize_url.(sanitized["url"], sanitized["username"])
        result = %{sanitized | "url" => normalized_url}

        log_discovery_success(success_event, metadata, extra_success_meta.(result))
        {:ok, result}

      {:error, errors} when is_map(errors) ->
        log_discovery_failure(failure_event, metadata, errors, extra_failure_meta.(errors))
        {:error, errors}
    end
  end

  defp validate_discovery_credentials(params, metadata) do
    with {:ok, sanitized_url} <- validate_server_url(params["url"], metadata),
         {:ok, sanitized_username} <- validate_username(params["username"], metadata),
         {:ok, sanitized_password} <- validate_password(params["password"], metadata) do
      {:ok,
       %{
         "url" => sanitized_url,
         "username" => sanitized_username,
         "password" => sanitized_password
       }}
    end
  end

  defp log_discovery_success(event, metadata, extra) do
    SecurityLogger.log_security_event(event, Map.merge(base_security_metadata(metadata), extra))
  end

  defp log_discovery_failure(event, metadata, errors, extra) do
    SecurityLogger.log_security_event(
      event,
      base_security_metadata(metadata)
      |> Map.merge(%{errors: Map.keys(errors)})
      |> Map.merge(extra)
    )
  end

  defp base_security_metadata(metadata) do
    %{
      ip_address: metadata[:ip],
      user_agent: metadata[:user_agent],
      user_id: metadata[:user_id]
    }
  end

  defp validate_calendar_url(url) do
    UrlValidation.validate_http_url(url,
      enforce_https_for_public: true,
      https_error_message: "Use HTTPS for non-local calendar servers"
    )
  end
end
