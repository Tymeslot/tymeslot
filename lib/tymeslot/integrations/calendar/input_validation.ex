defmodule Tymeslot.Integrations.Calendar.InputValidation do
  @moduledoc """
  Calendar integration input validation and sanitization.

  Provides specialized validation for calendar integration forms including
  Nextcloud and CalDAV configuration forms with URL, credential, and path validation.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CredentialFields
  alias Tymeslot.Integrations.Calendar.Ics.Feed
  alias Tymeslot.Integrations.Shared.InputValidators
  alias Tymeslot.Security.SecurityLogger

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
           InputValidators.validate_integration_name(params["name"], metadata),
         {:ok, sanitized_url} <- CredentialFields.server_url(params["url"], metadata),
         {:ok, sanitized_username} <- CredentialFields.username(params["username"], metadata),
         {:ok, sanitized_password} <- CredentialFields.password(params["password"], metadata),
         {:ok, sanitized_calendar_paths} <-
           CredentialFields.calendar_paths(params["calendar_paths"], metadata) do
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
  Validates the Exchange connection form (name, url, username, password,
  mailbox).

  Shares the first four fields with `validate_calendar_integration_form/2`
  and adds the one an EWS integration cannot work without: the mailbox the
  availability read is addressed to. `GetUserAvailability` names a mailbox,
  not a folder, and an on-premises server accepts a login
  (`DOMAIN\\samaccountname`) that is not itself addressable, so the address
  is collected as its own field rather than inferred from the username.

  No `calendar_paths`: an EWS folder is named by the opaque `FolderId` the
  server issues, and the form has no path input to validate.
  """
  @spec validate_exchange_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_exchange_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_name} <-
           InputValidators.validate_integration_name(params["name"], metadata),
         {:ok, sanitized_url} <- CredentialFields.server_url(params["url"], metadata),
         {:ok, sanitized_username} <- CredentialFields.username(params["username"], metadata),
         {:ok, sanitized_password} <- CredentialFields.password(params["password"], metadata),
         {:ok, sanitized_mailbox} <- CredentialFields.mailbox(params["mailbox"], metadata) do
      SecurityLogger.log_security_event("exchange_integration_form_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        provider: "exchange"
      })

      {:ok,
       %{
         "name" => sanitized_name,
         "url" => sanitized_url,
         "username" => sanitized_username,
         "password" => sanitized_password,
         "mailbox" => sanitized_mailbox
       }}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("exchange_integration_form_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          provider: "exchange",
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

    case InputValidators.validate_integration_name(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{name: error}} -> {:error, error}
    end
  end

  def validate_single_field(:url, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    normalised = if is_binary(value), do: Feed.normalise_url(value), else: value

    case CredentialFields.server_url(normalised, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{url: error}} -> {:error, error}
    end
  end

  def validate_single_field(:username, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case CredentialFields.username(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{username: error}} -> {:error, error}
    end
  end

  def validate_single_field(:password, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case CredentialFields.password(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{password: error}} -> {:error, error}
    end
  end

  def validate_single_field(:mailbox, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case CredentialFields.mailbox(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{mailbox: error}} -> {:error, error}
    end
  end

  def validate_single_field(:calendar_paths, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case CredentialFields.calendar_paths(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{calendar_paths: error}} -> {:error, error}
    end
  end

  def validate_single_field(_field, _value, _opts), do: {:ok, nil}

  @doc """
  Validates the calendar subscription form (name and feed URL).

  Deliberately separate from `validate_calendar_integration_form/2` rather
  than a credentials-optional mode of it: a subscription has no username or
  password to make optional, and threading a "are credentials required here?"
  flag through the shared path would put every CalDAV provider's credential
  checks one wrong argument away from being skipped.

  The `webcal://` scheme every vendor's "subscribe" button hands out is
  rewritten to `https://` before validation, since that is what it means and
  what we will actually request.
  """
  @spec validate_ics_subscription_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_ics_subscription_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_name} <-
           InputValidators.validate_integration_name(params["name"], metadata),
         {:ok, sanitized_url} <- validate_subscription_url(params["url"], metadata) do
      SecurityLogger.log_security_event("calendar_subscription_form_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        url: CredentialFields.sanitize_url_for_logging(sanitized_url)
      })

      {:ok, %{"name" => sanitized_name, "url" => sanitized_url}}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("calendar_subscription_form_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  # Unlike a CalDAV server address, a feed URL is required: without it there
  # is nothing at all to subscribe to.
  defp validate_subscription_url(nil, _metadata) do
    {:error, %{url: "Enter the calendar feed URL"}}
  end

  # Deliberately does not go through `validate_server_url/2`: that path runs
  # `UniversalSanitizer` in `:strict` mode, which recursively percent-decodes
  # and then strips SQL-injection-shaped substrings (`--...`, `0x...`) from the
  # URL before it is ever probed or stored. Feed URLs routinely contain those
  # exact shapes as legitimate tokens (iCloud's `--` suffix, Google's `%40`
  # secret address, hex-looking path segments), so a feed URL is validated
  # directly against its raw bytes instead of through the text sanitiser.
  defp validate_subscription_url(url, _metadata) when is_binary(url) do
    case Feed.normalise_url(url) do
      "" -> {:error, %{url: "Enter the calendar feed URL"}}
      normalised -> validate_subscription_url_format(normalised)
    end
  end

  defp validate_subscription_url(_value, _metadata) do
    {:error, %{url: "Server URL must be text"}}
  end

  defp validate_subscription_url_format(url) do
    cond do
      not String.valid?(url) or String.contains?(url, "\x00") ->
        {:error, %{url: "URL contains invalid characters"}}

      String.length(url) > 2000 ->
        {:error, %{url: "URL must be 2000 characters or less"}}

      true ->
        case CredentialFields.validate_calendar_url(url) do
          :ok -> {:ok, url}
          {:error, error} -> {:error, %{url: error}}
        end
    end
  end

  @doc """
  Validates calendar discovery parameters for any CalDAV-based provider.

  Supports CalDAV, Radicale, Nextcloud, and other CalDAV-compatible providers.
  Every outcome is recorded as a security event, because this endpoint takes a
  URL and credentials from an authenticated user and makes the server connect
  to it.
  """
  @spec validate_calendar_discovery(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_calendar_discovery(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    provider = Keyword.get(opts, :provider, :caldav)

    case validate_discovery_credentials(params, metadata) do
      {:ok, sanitized} ->
        result = %{sanitized | "url" => normalize_base_url(provider, sanitized["url"])}

        log_discovery_success(provider, metadata, result)
        {:ok, result}

      {:error, errors} when is_map(errors) ->
        log_discovery_failure(provider, metadata, errors)
        {:error, errors}
    end
  end

  defp normalize_base_url(:radicale, url), do: normalize_radicale_base_url_for_discovery(url)
  defp normalize_base_url(_provider, url), do: url

  # Radicale-specific: sanitize common mistakes in base URL.
  # - If user included '/.web' (or '/.web/'), drop it.
  # - If user appended '/<username>' (with or without trailing slash), drop it.
  # - Always reduce to scheme://host[:port] (no path) for discovery base URL.
  defp normalize_radicale_base_url_for_discovery(url) do
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

  defp validate_discovery_credentials(params, metadata) do
    with {:ok, sanitized_url} <- CredentialFields.server_url(params["url"], metadata),
         {:ok, sanitized_username} <- CredentialFields.username(params["username"], metadata),
         {:ok, sanitized_password} <- CredentialFields.password(params["password"], metadata) do
      {:ok,
       %{
         "url" => sanitized_url,
         "username" => sanitized_username,
         "password" => sanitized_password
       }}
    end
  end

  defp log_discovery_success(provider, metadata, sanitized) do
    SecurityLogger.log_security_event(
      "#{provider}_discovery_validation_success",
      Map.merge(base_security_metadata(metadata), %{
        url: CredentialFields.sanitize_url_for_logging(sanitized["url"]),
        provider: provider
      })
    )
  end

  # Only the error *keys* are logged: the values are user-facing messages and
  # the submitted credentials must never reach the log.
  defp log_discovery_failure(provider, metadata, errors) do
    SecurityLogger.log_security_event(
      "#{provider}_discovery_validation_failure",
      Map.merge(base_security_metadata(metadata), %{
        errors: Map.keys(errors),
        provider: provider
      })
    )
  end

  defp base_security_metadata(metadata) do
    %{
      ip_address: metadata[:ip],
      user_agent: metadata[:user_agent],
      user_id: metadata[:user_id]
    }
  end
end
