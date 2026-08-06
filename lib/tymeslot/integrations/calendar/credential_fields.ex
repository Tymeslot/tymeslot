defmodule Tymeslot.Integrations.Calendar.CredentialFields do
  @moduledoc """
  Field-level validation and sanitisation of CalDAV credential input.

  One function per field a user types when connecting a calendar server: the
  URL, the username, the password, and the calendar paths. Each sanitises its
  input and returns either the cleaned value or a `%{field => message}` error
  ready to render against that field.

  These are shared by the two surfaces that collect the same credentials — the
  integration form and the discovery/test-connection probe — so that a rule
  tightened for one automatically holds for the other. `validate_calendar_url/1`
  is the one that matters most: it blocks loopback, link-local and RFC 1918
  addresses, which is what stops an authenticated user using the connect form to
  probe the server's own network.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Shared.InputValidators
  alias Tymeslot.Security.UniversalSanitizer
  alias Tymeslot.Security.UrlValidation

  @doc "Validates a CalDAV server URL. Optional: a blank URL is accepted."
  @spec server_url(term(), map()) :: {:ok, String.t()} | {:error, map()}
  def server_url(value, metadata), do: validate_server_url(value, metadata)

  @doc "Validates a required username."
  @spec username(term(), map()) :: {:ok, String.t()} | {:error, map()}
  def username(value, metadata), do: validate_username(value, metadata)

  @doc "Validates a required password."
  @spec password(term(), map()) :: {:ok, String.t()} | {:error, map()}
  def password(value, metadata), do: validate_password(value, metadata)

  @doc "Validates the optional calendar-path list, accepting `\"*\"` for auto-discovery."
  @spec calendar_paths(term(), map()) :: {:ok, String.t()} | {:error, map()}
  def calendar_paths(value, metadata), do: validate_calendar_paths(value, metadata)

  @doc """
  Validates a calendar server URL, rejecting internal network addresses.

  Mirrors the persistence posture in `CalendarIntegrationSchema`, which
  validates `:base_url` with `block_private_ips: true`. Discovery,
  test-connection and feed-subscription forms must all reject internal hosts
  (loopback, link-local, RFC 1918) so an authenticated user cannot probe them
  server-side any more than they can save such a URL on an integration.
  """
  @spec validate_calendar_url(term()) :: :ok | {:error, String.t()}
  def validate_calendar_url(url), do: do_validate_calendar_url(url)

  @doc """
  Redacts a URL down to scheme and host for logging.
  """
  @spec sanitize_url_for_logging(term()) :: String.t()
  def sanitize_url_for_logging(url), do: do_sanitize_url_for_logging(url)

  # Optional for some providers
  defp validate_server_url(nil, _metadata), do: {:ok, ""}
  defp validate_server_url("", _metadata), do: {:ok, ""}

  defp validate_server_url(url, metadata) when is_binary(url) do
    case InputValidators.validate_server_url(url, metadata,
           error_message:
             dgettext(
               "dashboard_calendar_providers",
               "Please enter a valid server URL (e.g., https://cloud.example.com)"
             ),
           validate_url_fn: &do_validate_calendar_url/1
         ) do
      {:ok, sanitized_url} -> {:ok, sanitized_url}
      {:error, error} -> {:error, %{url: error}}
    end
  end

  defp validate_server_url(_value, _metadata) do
    {:error, %{url: dgettext("dashboard_calendar_providers", "Server URL must be text")}}
  end

  defp validate_username(nil, _metadata), do: {:error, %{username: username_required_message()}}
  defp validate_username("", _metadata), do: {:error, %{username: username_required_message()}}

  defp validate_username(username, metadata) when is_binary(username) do
    case UniversalSanitizer.sanitize_and_validate(username, allow_html: false, metadata: metadata) do
      {:ok, sanitized_username} ->
        cond do
          String.length(sanitized_username) > 255 ->
            {:error,
             %{
               username:
                 dgettext(
                   "dashboard_calendar_providers",
                   "Username must be 255 characters or less"
                 )
             }}

          String.length(String.trim(sanitized_username)) < 1 ->
            {:error, %{username: username_required_message()}}

          true ->
            {:ok, String.trim(sanitized_username)}
        end

      {:error, error} ->
        {:error, %{username: error}}
    end
  end

  defp validate_username(_value, _metadata) do
    {:error, %{username: dgettext("dashboard_calendar_providers", "Username must be text")}}
  end

  defp validate_password(nil, _metadata), do: {:error, %{password: password_required_message()}}
  defp validate_password("", _metadata), do: {:error, %{password: password_required_message()}}

  defp validate_password(password, _metadata) when is_binary(password) do
    cond do
      not String.valid?(password) ->
        {:error, %{password: password_invalid_characters_message()}}

      String.contains?(password, "\x00") ->
        {:error, %{password: password_invalid_characters_message()}}

      String.length(password) > 500 ->
        {:error,
         %{
           password:
             dgettext("dashboard_calendar_providers", "Password must be 500 characters or less")
         }}

      String.length(String.trim(password)) < 1 ->
        {:error, %{password: password_required_message()}}

      true ->
        {:ok, password}
    end
  end

  defp validate_password(_value, _metadata) do
    {:error, %{password: dgettext("dashboard_calendar_providers", "Password must be text")}}
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

  defp validate_calendar_paths(_value, _metadata) do
    {:error,
     %{calendar_paths: dgettext("dashboard_calendar_providers", "Calendar paths must be text")}}
  end

  defp validate_calendar_paths_format(paths) do
    if String.length(paths) > 5000 do
      {:error,
       dgettext("dashboard_calendar_providers", "Calendar paths must be 5000 characters or less")}
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
       dgettext(
         "dashboard_calendar_providers",
         "Some calendar paths have invalid format. Use full URLs (https://...) or paths (/calendar/)"
       )}
    end
  end

  defp invalid_path?(path) do
    cond do
      String.starts_with?(path, ["http://", "https://"]) ->
        case do_validate_calendar_url(path) do
          :ok -> false
          _error -> true
        end

      String.starts_with?(path, "/") ->
        false

      true ->
        true
    end
  end

  # Mirrors the persistence posture in `CalendarIntegrationSchema`, which
  # validates `:base_url` with `block_private_ips: true`. Discovery/test-connection
  # forms must reject internal hosts (loopback, link-local, RFC 1918) so an
  # authenticated user can't probe them server-side any more than they can save
  # such a URL on the integration.
  defp do_validate_calendar_url(url) do
    UrlValidation.validate_http_url(url,
      enforce_https_for_public: true,
      block_private_ips: true,
      https_error_message:
        dgettext("dashboard_calendar_providers", "Use HTTPS for non-local calendar servers"),
      private_ip_error_message:
        dgettext(
          "dashboard_calendar_providers",
          "Private or local network addresses are not allowed"
        )
    )
  end

  defp username_required_message,
    do: dgettext("dashboard_calendar_providers", "Username is required")

  defp password_required_message,
    do: dgettext("dashboard_calendar_providers", "Password is required")

  defp password_invalid_characters_message,
    do: dgettext("dashboard_calendar_providers", "Password contains invalid characters")

  # Strips any userinfo so credentials embedded in a URL never reach the logs.
  defp do_sanitize_url_for_logging(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | userinfo: nil})
  end
end
