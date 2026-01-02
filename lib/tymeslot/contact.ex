defmodule Tymeslot.Contact do
  @moduledoc """
  Context module for handling contact form operations.
  """

  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Security.{InputProcessor, RateLimiter}

  alias Tymeslot.Security.FieldValidators.{
    EmailValidator,
    MessageValidator,
    NameValidator,
    TextValidator
  }

  alias Tymeslot.Workers.EmailWorker

  @doc """
  Validates and processes a contact form submission.

  Returns `{:ok, job}` on success or `{:error, reason}` on failure.
  """
  @spec submit_contact_form(map(), String.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, atom()} | {:error, atom(), any()}
  def submit_contact_form(contact_params, recaptcha_token, client_ip) do
    with :ok <- check_rate_limit(client_ip),
         {:ok, _} <- RecaptchaHelpers.validate_token(recaptcha_token),
         {:ok, validated_params} <- validate_contact_input(contact_params, client_ip) do
      send_contact_email(validated_params)
    else
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
      {:error, :invalid_input, errors} -> {:error, :invalid_input, errors}
      {:error, _} -> {:error, :recaptcha_failed}
    end
  end

  @doc """
  Validates contact form input parameters for real-time validation.

  Returns `{:ok, validated_params}` or `{:error, errors}`.
  """
  @spec validate_form_input(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def validate_form_input(contact_params, client_ip) do
    metadata = %{ip: client_ip}

    case InputProcessor.validate_form(
           contact_params,
           [
             {"name", NameValidator},
             {"email", EmailValidator},
             {"subject", TextValidator},
             {"message", MessageValidator}
           ],
           metadata: metadata
         ) do
      {:ok, sanitized_params} -> {:ok, sanitized_params}
      {:error, errors} -> {:error, errors}
    end
  end

  defp check_rate_limit(client_ip) do
    case RateLimiter.check_rate("contact_form:#{client_ip}", 600_000, 5) do
      {:allow, _count} ->
        :ok

      {:deny, _limit} ->
        {:error, :rate_limited,
         "Too many contact form submissions. Please try again in 10 minutes."}
    end
  end

  defp validate_contact_input(params, client_ip) do
    metadata = %{ip: client_ip}

    universal_opts = [
      max_length: Application.get_env(:tymeslot, :field_validation)[:universal_max_length],
      allow_html: false
    ]

    case InputProcessor.validate_form(
           params,
           [
             {"name", NameValidator},
             {"email", EmailValidator},
             {"subject", TextValidator},
             {"message", MessageValidator}
           ],
           metadata: metadata,
           universal_opts: universal_opts
         ) do
      {:ok, sanitized_params} -> {:ok, sanitized_params}
      {:error, errors} -> {:error, :invalid_input, errors}
    end
  end

  defp send_contact_email(params) do
    %{
      "name" => name,
      "email" => email,
      "subject" => subject,
      "message" => message
    } = params

    email_params = %{
      "action" => "send_contact_form",
      "sender_name" => String.trim(name),
      "sender_email" => String.trim(email),
      "subject" => String.trim(subject),
      "message" => String.trim(message),
      "recipient" => Application.get_env(:tymeslot, :email)[:contact_recipient]
    }

    Oban.insert(EmailWorker.new(email_params))
  end
end
