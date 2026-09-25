defmodule Tymeslot.Integrations.Video.InputValidation do
  @moduledoc """
  Video integration input validation and sanitization.

  Provides specialized validation for video integration forms including
  MiroTalk, kMeet, Jitsi, Nextcloud Talk and Custom Video configuration forms.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Shared.InputValidators
  alias Tymeslot.Integrations.Video.{TemplateConfig, TemplateSyntax}
  alias Tymeslot.Security.{SecurityLogger, SsrfGuard, UniversalSanitizer, UrlValidation}

  @malformed_escape ~r/%(?![0-9A-Fa-f]{2})/

  @doc """
  Validates video integration form input based on provider type.

  ## Parameters
  - `params` - Map containing video integration form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`

  `sanitized_params` holds every field the provider's form accepts and nothing
  else, so callers pass it on in place of the submitted params.
  """
  @spec validate_video_integration_form(%{String.t() => term()}, keyword()) ::
          {:ok, %{String.t() => term()}} | {:error, %{atom() => String.t()}}
  def validate_video_integration_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    provider = params["provider"]

    case provider do
      "mirotalk" ->
        validate_mirotalk_form(params, metadata)

      "custom" ->
        validate_custom_video_form(params, metadata)

      "kmeet" ->
        validate_kmeet_form(params, metadata)

      "jitsi" ->
        validate_jitsi_form(params, metadata)

      "nextcloud_talk" ->
        validate_nextcloud_talk_form(params, metadata)

      _unknown_provider ->
        SecurityLogger.log_security_event("video_integration_unknown_provider", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          provider: provider
        })

        {:error, %{provider: dgettext("dashboard_integrations", "Unknown video provider")}}
    end
  end

  @doc """
  Validates a single field for video integration form.

  ## Parameters
  - `field` - The field name as atom (:name, :api_key, :base_url, :custom_meeting_url)
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

  def validate_single_field(:api_key, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_api_key(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{api_key: error}} -> {:error, error}
    end
  end

  def validate_single_field(:base_url, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_base_url(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{base_url: error}} -> {:error, error}
    end
  end

  def validate_single_field(:custom_meeting_url, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_url(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{custom_meeting_url: error}} -> {:error, error}
    end
  end

  def validate_single_field(_other_field, _value, _opts), do: {:ok, nil}

  # Private validation functions for each provider type

  defp validate_mirotalk_form(params, metadata) do
    with {:ok, sanitized_name} <-
           InputValidators.validate_integration_name(params["name"], metadata),
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
           InputValidators.validate_integration_name(params["name"], metadata),
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

  # kMeet always runs on Infomaniak's fixed host, so the name is the only
  # thing the organiser supplies.
  defp validate_kmeet_form(params, metadata) do
    case InputValidators.validate_integration_name(params["name"], metadata) do
      {:ok, sanitized_name} ->
        {:ok, %{"name" => sanitized_name}}

      {:error, errors} ->
        SecurityLogger.log_security_event("kmeet_integration_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  defp validate_jitsi_form(params, metadata) do
    with {:ok, sanitized} <-
           validate_server_form(params, metadata, "jitsi_integration_validation_failure") do
      {:ok,
       Map.put(
         sanitized,
         "remove_token_authentication",
         params["remove_token_authentication"] == "true"
       )}
    end
  end

  defp validate_nextcloud_talk_form(params, metadata),
    do: validate_server_form(params, metadata, "nextcloud_talk_integration_validation_failure")

  # The shape shared by the providers that sign in to a server of the
  # organiser's choosing with a client id and secret (Jitsi's App ID and App
  # secret, Nextcloud Talk's login name and app password). The name is
  # validated and the server URL sanitised here; whether the URL and
  # credentials make a usable config is the provider's `validate_config/1`
  # call when the integration is saved, so the connect form and the edit dialog
  # share one set of rules and messages.
  #
  # The credentials are only trimmed and stripped of null bytes, which
  # PostgreSQL refuses: a secret may legitimately contain characters a
  # sanitiser would remove. A blank credential is left out of the result
  # altogether, so an edit that does not touch the credentials does not count
  # as supplying them.
  defp validate_server_form(params, metadata, failure_event) do
    with {:ok, sanitized_name} <-
           InputValidators.validate_integration_name(params["name"], metadata),
         {:ok, sanitized_base_url} <- sanitize_server_url(params["base_url"], metadata) do
      {:ok,
       Map.reject(
         %{
           "name" => sanitized_name,
           "base_url" => sanitized_base_url,
           "client_id" => credential(params["client_id"]),
           "client_secret" => credential(params["client_secret"])
         },
         fn {_field, value} -> is_nil(value) end
       )}
    else
      {:error, errors} ->
        SecurityLogger.log_security_event(failure_event, %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  # A blank URL is kept, so that the provider can refuse it with its own
  # message rather than an edit silently keeping the stored one.
  defp sanitize_server_url(base_url, metadata) when is_binary(base_url) do
    case UniversalSanitizer.sanitize_and_validate(base_url, allow_html: false, metadata: metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, error} -> {:error, %{base_url: error}}
    end
  end

  defp sanitize_server_url(_base_url, _metadata), do: {:ok, nil}

  defp credential(value) when is_binary(value) do
    case value |> String.replace("\x00", "") |> String.trim() do
      "" -> nil
      credential -> credential
    end
  end

  defp credential(_value), do: nil

  # Helper validation functions

  defp validate_api_key(nil, _metadata), do: {:error, %{api_key: api_key_required_message()}}
  defp validate_api_key("", _metadata), do: {:error, %{api_key: api_key_required_message()}}

  defp validate_api_key(api_key, metadata) when is_binary(api_key) do
    case UniversalSanitizer.sanitize_and_validate(api_key, allow_html: false, metadata: metadata) do
      {:ok, sanitized_api_key} ->
        cond do
          String.length(sanitized_api_key) > 500 ->
            {:error,
             %{
               api_key:
                 dgettext("dashboard_integrations", "API key must be 500 characters or less")
             }}

          String.length(String.trim(sanitized_api_key)) < 8 ->
            {:error,
             %{
               api_key:
                 dgettext("dashboard_integrations", "API key must be at least 8 characters")
             }}

          true ->
            {:ok, String.trim(sanitized_api_key)}
        end

      {:error, error} ->
        {:error, %{api_key: error}}
    end
  end

  defp validate_api_key(_other, _metadata) do
    {:error, %{api_key: dgettext("dashboard_integrations", "API key must be text")}}
  end

  defp validate_base_url(nil, _metadata), do: {:error, %{base_url: base_url_required_message()}}
  defp validate_base_url("", _metadata), do: {:error, %{base_url: base_url_required_message()}}

  # Also the on-blur check of the Nextcloud Talk and Jitsi server address, so
  # the private-address opt-out that lets those providers reach a server on a
  # Docker service name admits a single-label host here too.
  defp validate_base_url(base_url, metadata) when is_binary(base_url) do
    case InputValidators.validate_server_url(base_url, metadata,
           error_message:
             dgettext(
               "dashboard_integrations",
               "Please enter a valid server URL (e.g., https://mirotalk.example.com)"
             ),
           internal_names_local: SsrfGuard.allow_private_for_video?(),
           validate_url_fn: &validate_video_url/1
         ) do
      {:ok, sanitized_url} -> {:ok, sanitized_url}
      {:error, error} -> {:error, %{base_url: error}}
    end
  end

  defp validate_base_url(_other, _metadata) do
    {:error, %{base_url: dgettext("dashboard_integrations", "Base URL must be text")}}
  end

  defp validate_meeting_url(nil, _metadata),
    do: {:error, %{custom_meeting_url: meeting_url_required_message()}}

  defp validate_meeting_url("", _metadata),
    do: {:error, %{custom_meeting_url: meeting_url_required_message()}}

  defp validate_meeting_url(meeting_url, metadata) when is_binary(meeting_url) do
    trimmed_url = String.trim(meeting_url)

    # The template syntax is checked on the URL as typed, which is what gets
    # stored, and again on its percent-decoded reading.
    with {:ok, validated_url} <-
           InputValidators.validate_server_url(trimmed_url, metadata,
             error_message: invalid_meeting_url_error(trimmed_url),
             validate_url_fn: &validate_video_url/1
           ),
         :ok <- validate_meeting_url_template(validated_url) do
      {:ok, validated_url}
    else
      {:error, error} -> {:error, %{custom_meeting_url: error}}
    end
  end

  defp validate_meeting_url(_other, _metadata) do
    {:error,
     %{custom_meeting_url: dgettext("dashboard_integrations", "Meeting URL must be text")}}
  end

  @doc """
  Checks the `{{meeting_id}}` placeholder of a custom meeting URL exactly as a
  save does: on the URL as typed, and again on its percent-decoded reading.

  Returns `:ok` for a static URL or a correctly written template, and
  `{:error, message}` with the message the save form would show otherwise.
  Only the template syntax is checked, not the URL's shape or host, so a
  stored URL can be judged by the same rule the form enforces.
  """
  @spec validate_meeting_url_template(String.t()) :: :ok | {:error, String.t()}
  def validate_meeting_url_template(url) when is_binary(url) do
    with :ok <- TemplateSyntax.validate(url), do: validate_decoded_template(url)
  end

  # A URL that already names http or https and is still refused failed on its
  # own terms, so the message points at the URL. Anything else was given
  # `https://` before it was checked (`InputValidators.normalize_url_protocol/1`),
  # so what it was missing was the scheme: name the correction instead of the
  # rule, which is all "Only HTTP and HTTPS URLs are allowed" ever did.
  defp invalid_meeting_url_error("http://" <> _rest), do: malformed_meeting_url_message()
  defp invalid_meeting_url_error("https://" <> _rest), do: malformed_meeting_url_message()

  defp invalid_meeting_url_error(_scheme_less),
    do:
      dgettext(
        "dashboard_integrations",
        "Enter a full address starting with https://, for example https://meet.example.com"
      )

  defp malformed_meeting_url_message do
    dgettext(
      "dashboard_integrations",
      "Please enter a valid meeting URL (e.g., https://meet.google.com/abc-defg-hij)"
    )
  end

  # The URL is stored exactly as typed, and room creation substitutes the
  # literal `{{meeting_id}}`, so a placeholder hidden behind percent escapes is
  # never replaced and every booking silently lands in the same room. Both
  # shapes are refused: escaped and malformed (`%7Bmeeting_id%7D`), and escaped
  # but otherwise correct (`%7B%7Bmeeting_id%7D%7D`).
  defp validate_decoded_template(url) do
    decoded = decode_percent_escapes(url)

    cond do
      decoded == url -> :ok
      escaped_template?(url, decoded) -> {:error, escaped_template_message()}
      true -> TemplateSyntax.validate(decoded)
    end
  end

  defp escaped_template?(url, decoded) do
    match?({:ok, :valid_template, _preview, _message}, TemplateSyntax.analyze(decoded)) and
      not String.contains?(url, TemplateConfig.template_variable())
  end

  # A `%` that does not introduce a well-formed escape has nothing to decode
  # (and makes `URI.decode/1` raise), and a decode that does not land on valid
  # text is not a reading anyone could have meant. Either way the URL as typed
  # stands on its own.
  defp decode_percent_escapes(url) do
    decoded = if Regex.match?(@malformed_escape, url), do: url, else: URI.decode(url)

    if String.valid?(decoded), do: decoded, else: url
  end

  defp validate_video_url(url) do
    UrlValidation.validate_http_url(url,
      extra_checks: &validate_external_video_host/1,
      disallowed_protocol_error: http_https_only_message(),
      invalid_message:
        dgettext(
          "dashboard_integrations",
          "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"
        )
    )
  end

  defp validate_external_video_host(%{host: host}) do
    if video_host_allowed?(host) do
      :ok
    else
      {:error, dgettext("dashboard_integrations", "Invalid hostname in URL")}
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

  defp api_key_required_message, do: dgettext("dashboard_integrations", "API key is required")

  defp base_url_required_message, do: dgettext("dashboard_integrations", "Base URL is required")

  defp meeting_url_required_message,
    do: dgettext("dashboard_integrations", "Meeting URL is required")

  defp http_https_only_message,
    do: dgettext("dashboard_integrations", "Only HTTP and HTTPS URLs are allowed")

  defp escaped_template_message,
    do:
      dgettext(
        "dashboard_integrations",
        "Write {{meeting_id}} with plain brackets: percent-encoded ones are never replaced"
      )
end
