defmodule Tymeslot.Security.AuthValidation do
  @moduledoc """
  Validation functions for authentication-related input.
  Includes sanitization to prevent malicious content.
  """

  alias Tymeslot.Security.UniversalSanitizer
  alias Tymeslot.Deployment

  @doc """
  Validates login input (email and password).
  """
  @spec validate_login_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_login_input(%{"email" => email, "password" => password} = params) do
    with {:ok, sanitized_email} <- validate_and_sanitize_email(email),
         {:ok, _} <- validate_password_presence(password) do
      {:ok, %{params | "email" => sanitized_email}}
    else
      {:error, field, message} ->
        {:error, %{field => [message]}}
    end
  end

  def validate_login_input(_), do: {:error, %{base: ["Invalid input format"]}}

  @doc """
  Validates signup input.
  """
  @spec validate_signup_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_signup_input(params) when is_map(params) do
    with {:ok, sanitized_email} <- validate_and_sanitize_email(params["email"]),
         {:ok, _} <- validate_password_if_provided(params["password"]),
         {:ok, sanitized_full_name} <- validate_and_sanitize_full_name(params["full_name"]),
         :ok <- if(Deployment.main?(), do: validate_terms_accepted_to_ok(params["terms_accepted"]), else: :ok) do
      result_params = %{params | "email" => sanitized_email}

      result_params =
        if sanitized_full_name,
          do: Map.put(result_params, "full_name", sanitized_full_name),
          else: result_params

      {:ok, result_params}
    else
      {:error, field, message} ->
        {:error, %{field => [message]}}
    end
  end

  def validate_signup_input(_), do: {:error, %{base: ["Invalid input format"]}}

  # Private validation helper

  defp validate_terms_accepted_to_ok(value) do
    case validate_terms_accepted(value) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Validates password reset input.
  """
  @spec validate_password_reset_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_password_reset_input(%{"email" => email} = params) when is_binary(email) do
    case validate_and_sanitize_email(email) do
      {:ok, sanitized_email} ->
        {:ok, %{params | "email" => sanitized_email}}

      {:error, field, message} ->
        {:error, %{field => [message]}}
    end
  end

  def validate_password_reset_input(
        %{"password" => password, "password_confirmation" => confirmation} = params
      ) do
    with {:ok, _} <- validate_password(password),
         {:ok, _} <- validate_password_confirmation(password, confirmation) do
      {:ok, params}
    else
      {:error, field, message} ->
        {:error, %{field => [message]}}
    end
  end

  def validate_password_reset_input(_), do: {:error, %{base: ["Invalid input format"]}}

  # Private validation functions

  defp validate_and_sanitize_email(email) when is_binary(email) do
    trimmed = email |> String.trim() |> String.downcase()

    case UniversalSanitizer.sanitize_and_validate(trimmed, allow_html: false, max_length: 160) do
      {:ok, sanitized} ->
        cond do
          sanitized == "" ->
            {:error, :email, "can't be blank"}

          not valid_email_format?(sanitized) ->
            {:error, :email, "has invalid format"}

          contains_malicious_patterns?(sanitized) ->
            {:error, :email, "contains invalid characters"}

          true ->
            {:ok, sanitized}
        end

      {:error, reason} ->
        {:error, :email, reason}
    end
  end

  defp validate_and_sanitize_email(_), do: {:error, :email, "can't be blank"}

  defp validate_and_sanitize_full_name(nil), do: {:ok, nil}
  defp validate_and_sanitize_full_name(""), do: {:ok, nil}

  defp validate_and_sanitize_full_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    case UniversalSanitizer.sanitize_and_validate(trimmed, allow_html: false, max_length: 100) do
      {:ok, sanitized} ->
        cond do
          String.length(sanitized) < 1 ->
            {:ok, nil}

          contains_malicious_patterns?(sanitized) ->
            {:error, :full_name, "contains invalid characters"}

          true ->
            {:ok, sanitized}
        end

      {:error, reason} ->
        {:error, :full_name, reason}
    end
  end

  defp validate_and_sanitize_full_name(_), do: {:error, :full_name, "must be text"}

  defp validate_password_presence(password) when is_binary(password) and password != "" do
    {:ok, password}
  end

  defp validate_password_presence(_), do: {:error, :password, "can't be blank"}

  defp validate_password_if_provided(nil), do: {:ok, nil}
  defp validate_password_if_provided(""), do: {:ok, nil}
  defp validate_password_if_provided(password), do: validate_password(password)

  defp validate_password(password) when is_binary(password) do
    cond do
      String.length(password) < 8 ->
        {:error, :password, "should be at least 8 character(s)"}

      String.length(password) > 80 ->
        {:error, :password, "should be at most 80 character(s)"}

      not String.match?(password, ~r/[a-z]/) ->
        {:error, :password, "must contain at least one lower case character"}

      not String.match?(password, ~r/[A-Z]/) ->
        {:error, :password, "must contain at least one upper case character"}

      not String.match?(password, ~r/[0-9]/) ->
        {:error, :password, "must contain at least one digit"}

      true ->
        {:ok, password}
    end
  end

  defp validate_password(_), do: {:error, :password, "can't be blank"}

  defp validate_password_confirmation(password, confirmation) when password == confirmation do
    {:ok, confirmation}
  end

  defp validate_password_confirmation(_, _),
    do: {:error, :password_confirmation, "does not match password"}

  defp validate_terms_accepted("true"), do: {:ok, true}
  defp validate_terms_accepted(true), do: {:ok, true}
  defp validate_terms_accepted("on"), do: {:ok, true}
  defp validate_terms_accepted(_), do: {:error, :terms_accepted, "must be accepted"}

  defp valid_email_format?(email) do
    String.match?(email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
  end

  defp contains_malicious_patterns?(text) do
    malicious_patterns = [
      ~r/<script/i,
      ~r/javascript:/i,
      ~r/on\w+=/i,
      ~r/data:text\/html/i,
      ~r/vbscript:/i,
      ~r/onmouseover=/i,
      ~r/onclick=/i,
      ~r/onerror=/i
    ]

    Enum.any?(malicious_patterns, &String.match?(text, &1))
  end
end
